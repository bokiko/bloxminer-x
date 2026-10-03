#!/usr/bin/env bash
# Reproduces the real-rig bug found on cask10 (5950X, all 32 threads mining): h-stats.sh's /proc ownership and
# task-mask scans must stay O(1) forks regardless of BOTH process-table size AND actual CPU load - a per-item
# fork loop was fast enough on an idle dev box to hide the problem entirely, but slow enough under real CPU
# load (fork/exec latency multiplies badly when every core is busy) to blow the whole 3.0 s budget and make
# Hive's watchdog see 0 H/s and reboot the rig. Every case here saturates CPUs for its own duration only, and
# unconditionally cleans up (busy loops, any real xmrig) via a trap even on failure. bloxsense is never an
# instant fixture here: case 1 uses one that genuinely sleeps ~0.55 s (matching the real bloxsense's own RAPL
# two-read sample), and case 2 uses the actual compiled bloxsense binary when available - so the measured wall
# times reflect true end-to-end latency under load, not an artificially fast stand-in.
# Usage: tests/hive/test_under_load.sh (needs jq, curl, python3, bash, nproc; case 2 additionally needs a
# built xmrig - e.g. from build/build.sh - at $BLOX_XMRIG_BIN, default ~/bxwork/out/xmrig, plus optionally the
# real bloxsense at $BLOX_BLOXSENSE_BIN, default ~/bxwork/out/bloxsense; case 2 is skipped if xmrig is not
# present, unless BLOX_REQUIRE_REAL_ENGINE=1 - CI's under-load-real job sets it, so there a missing binary, or
# falling back to the bloxsense fixture, is a FAIL instead of a silent skip)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer-x" && pwd)
T=$(mktemp -d)
BUSY_PIDS=()
XMRIG_PID=""
cleanup() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	[[ -n $XMRIG_PID ]] && kill -9 "$XMRIG_PID" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-70s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-70s FAIL: %s\n' "$1" "$2"; }

saturate_cpus() {   # starts nproc pure-bash-builtin busy loops across the WHOLE host (no exec, so a plain -9
	# always reaps them cleanly) - used only by the UNTASKSET full-host cases below (case 1/2's "every core is
	# busy", case 3's own full-load sustained-polling run), which are each deliberately reproducing a REAL rig
	# with ALL its own cores mining - that scenario is correctly host-size-relative BY DEFINITION ("the whole
	# host, saturated" scales with however many cores the host actually has, no inconsistency to fix there).
	# Never used by a TASKSET-PINNED tier test - see saturate_tier()/K below for why.
	local n; n=$(nproc)
	BUSY_PIDS=()
	for _ in $(seq 1 "$n"); do
		sh -c 'while :; do :; done' &
		BUSY_PIDS+=("$!")
	done
}
# K: how many busy loops saturate_tier() starts PER CPU IN THE TIER under test - fixed, and the SAME value
# everywhere in this file a specific taskset tier (not the whole host) is being tested: case 3's 1/2/3-CPU
# tiers, and case 4's single-pinned-CPU test. A bot-review finding (sibling v3/v4 packages' own load tests):
# using plain nproc busy loops for a TIERED test makes its severity scale with the HOST running the test, not
# the tier being tested - 24x oversubscription of a 1-CPU tier on a 24-core box like ai02, but only 2-4x on a
# typical GitHub Actions runner, matching neither a real low-core rig nor anything reproducible across hosts.
# K * (CPUs in the tier) is host-size-independent instead: the same, deliberately generous oversubscription
# factor for a given tier no matter how many OTHER cores the test happens to be running on.
K=4
saturate_tier() {   # $1 = CPUs in the tier under test - starts K * $1 busy loops, never nproc-based
	local n=$(( K * $1 ))
	BUSY_PIDS=()
	for _ in $(seq 1 "$n"); do
		sh -c 'while :; do :; done' &
		BUSY_PIDS+=("$!")
	done
}
stop_saturating() {   # shared by saturate_cpus() and saturate_tier() - both fill the same $BUSY_PIDS
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	wait "${BUSY_PIDS[@]}" 2>/dev/null
	BUSY_PIDS=()
}

# AVAIL_CPUS: this process's OWN current CPU affinity, expanded from /proc/self/status's Cpus_allowed_list (a
# range-list like "2-4,7"), NOT assumed to be "0..nproc-1" - a bot-review finding (sibling package): every
# `taskset -c "0-$hi"`/`taskset -c 0` in this file used to build its CPU IDs from a literal 0 upward, which
# breaks outright if THIS SUITE ITSELF is invoked under a restricted affinity (e.g. `taskset -c 2-4 bash
# tests/hive/test_under_load.sh`, the exact scenario this fix is verified under) - CPU 0 may not even be in the
# set this process is permitted to run on, and `taskset -c 0 ...` then fails to pin anything at all rather than
# testing a real 1-CPU tier. Computed once, up front - this process's own affinity does not change mid-run.
AVAIL_CPUS=()
available_cpus() {
	AVAIL_CPUS=()
	local line list part lo hi parts
	line=$(grep '^Cpus_allowed_list:' /proc/self/status 2>/dev/null)
	list=${line#Cpus_allowed_list:}
	list=${list//[[:space:]]/}
	if [[ -z $list ]]; then
		# No /proc/self/status (non-Linux test host) - fall back to assuming the full 0..nproc-1 range, the
		# previous behavior, rather than leaving AVAIL_CPUS empty and skipping every tier unnecessarily.
		local n; n=$(nproc)
		for ((c = 0; c < n; c++)); do AVAIL_CPUS+=("$c"); done
		return
	fi
	IFS=',' read -ra parts <<< "$list"
	for part in "${parts[@]}"; do
		if [[ $part == *-* ]]; then
			lo=${part%-*}; hi=${part#*-}
			for ((c = lo; c <= hi; c++)); do AVAIL_CPUS+=("$c"); done
		else
			AVAIL_CPUS+=("$part")
		fi
	done
}
available_cpus
first_n_cpus() {   # $1 = how many CPU IDs are needed; on success sets $REPLY to a comma-joined `taskset -c`
	# argument built from the FIRST $1 entries of $AVAIL_CPUS (this process's own real affinity, never a
	# literal 0..$1-1 guess) - returns 1, REPLY empty, if fewer than $1 CPUs are available to this process at
	# all; callers SKIP that tier with a message in that case rather than silently pinning to the wrong CPUs.
	REPLY=""
	(( ${#AVAIL_CPUS[@]} >= $1 )) || return 1
	local IFS=','
	REPLY="${AVAIL_CPUS[*]:0:$1}"
}

# ================================================================== case 1: fake /proc (~1500 fds/375 procs), full CPU load
BLOX_DIR="$T/pkg"; mkdir -p "$BLOX_DIR" "$T/log"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer-x#" "$PKGSRC/h-manifest.conf" > "$BLOX_DIR/h-manifest.conf"
jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config.json"
: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"   # placeholder: only its path is compared (exe symlink target), never run

BLOXSENSE_JSON=$(python3 -c '
import json
cpus = [{"cpu": c, "pkg": 0, "core": c % 16, "temp": 60, "src": "core"} for c in range(32)]
print(json.dumps({"cpus": cpus, "pkg_temp": 65, "power_w": None, "ccd_reason": "test fixture"}))
')
# Sleeps ~0.55 s like the real bloxsense's own RAPL two-read sample, instead of answering instantly - so the
# wall-time measurement below reflects genuine end-to-end latency under load, not an artificially fast fixture.
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/sh
sleep 0.55
echo '$BLOXSENSE_JSON'
EOF
chmod +x "$BLOX_DIR/bloxsense"

PROC="$T/proc"
python3 - "$PROC" "$BLOX_DIR/xmrig" <<'PY'
import os, sys
root, xmrig_path = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(root, "net"), exist_ok=True)
TARGET_PID = "9001"
TARGET_INODE = 555555
n = 0
for i in range(2000, 2375):   # 375 unrelated processes x 4 fds = ~1500 fds, none matching our inode
	fddir = os.path.join(root, str(i), "fd")
	os.makedirs(fddir, exist_ok=True)
	for j in range(4):
		os.symlink("socket:[%d]" % (900000 + n), os.path.join(fddir, str(j)))
		n += 1
fddir = os.path.join(root, TARGET_PID, "fd")
os.makedirs(fddir, exist_ok=True)
os.symlink("socket:[%d]" % TARGET_INODE, os.path.join(fddir, "23"))
os.symlink(xmrig_path, os.path.join(root, TARGET_PID, "exe"))
taskdir = os.path.join(root, TARGET_PID, "task")
for c in range(32):   # 16C/32T: matches the bloxsense fixture's core mapping (c % 16)
	d = os.path.join(taskdir, str(c))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t%d\n" % c)
hexport = "%04X" % 4069
with open(os.path.join(root, "net", "tcp"), "w") as f:
	f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n")
	f.write("   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 100 0 0 10 0\n" % (hexport, TARGET_INODE))
PY

# hashrate.total[0] = 16496 (H/s): the sum of BACK_OK's own 32 per-thread rates below (500+c for c in 0..31) -
# real XMRig always reports summary.hashrate.total as that sum (null/0 only in the first seconds after startup,
# when the threads themselves are still null too - see the dedicated startup case near the end of this file).
# A CI trace (bot review) caught this fixture reporting hashrate-less (summary total 0) while BACK_OK's own
# threads were healthy and non-null - a shape no real rig can produce - which made Phase A's own honest 0 look
# like a false zero once Phase B ran out of time on a slow runner, when the real bug was an unrealistic fixture.
SUM_OK=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0", hashrate: {total: [16496.0]}}')
BACK_OK=$(python3 -c '
import json
threads = [{"affinity": c, "hashrate": [500.0 + c, None, None]} for c in range(32)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
')
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_OK" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 4069 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
grep -q ready "$T/api.out" || { bad "fake /proc under full CPU load" "fake API did not start: $(cat "$T/api.out")"; }

export BLOX_DIR BLOX_PROCFS_ROOT="$PROC" BLOX_API_PORT=4069
# P2 (bot review): under full-host saturation, Phase B legitimately does not always finish in time - falling
# back to Phase A's own single-row total is the DESIGNED degradation (see the file header's whole Phase A/B
# split), not a bug, so a bare "must be exactly 16 rows" assertion here could fail CI on a contended runner
# with no real regression. Not simply dropped, though: this fixture's own 16-row shape is what caught a real
# per-core regression before (f619829) - split into two checks instead. This one tolerates the fallback (EITHER
# 16 per-core rows OR exactly Phase A's 1-row total, counted and printed), but still requires the SAME expected
# total and a valid stats shape either way - a dedicated, UNLOADED regression guard for "16 rows, every time"
# follows right after this one.
saturate_cpus
sleep 0.3   # let the busy loops actually load every core before measuring
N_POLLS1=5
n_percore=0; n_fallback=0; n_bad1=0; max_elapsed1=0
for i in $(seq 1 "$N_POLLS1"); do
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	awk -v e="$elapsed" -v m="$max_elapsed1" 'BEGIN{exit !(e > m)}' && max_elapsed1=$elapsed
	khs=$(jq -r '.khs' <<< "$res" 2>/dev/null)
	nrows=$(jq -r '.stats.hs | length' <<< "$res" 2>/dev/null)
	valid_shape=false
	jq -e '(.stats | type) == "object" and (.stats.hs | type) == "array" and (.stats.hs | length) > 0 and
		(.stats.hs | all(type == "number")) and (.stats.temp | type) == "array"' > /dev/null 2>&1 <<< "$res" && valid_shape=true
	poll1_bad=1
	if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && [[ $khs == 16.50 ]] && [[ $valid_shape == true ]]; then
		if [[ $nrows == 16 ]]; then n_percore=$((n_percore+1)); poll1_bad=0
		elif [[ $nrows == 1 ]]; then n_fallback=$((n_fallback+1)); poll1_bad=0
		fi
	fi
	if (( poll1_bad )); then n_bad1=$((n_bad1+1)); echo "  poll $i: unexpected (elapsed=${elapsed}s khs=$khs rows=$nrows res=$res)"; fi
done
stop_saturating
if (( n_bad1 == 0 )); then
	ok "fake /proc (~1500 fds/375 procs) under full CPU load: khs=16.50 every poll, $n_percore/$N_POLLS1 per-core (16 rows), $n_fallback/$N_POLLS1 Phase A fallback (1 row), < 3.0 s (max ${max_elapsed1}s)"
else
	bad "fake /proc (~1500 fds/375 procs) under full CPU load: khs=16.50, 16-or-1 rows, valid shape, < 3.0 s, every poll" \
		"n_bad=$n_bad1/$N_POLLS1 n_percore=$n_percore n_fallback=$n_fallback max=${max_elapsed1}s"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null

# ---- the regression guard case 1's own relaxation above gives up: on an UNLOADED (or lightly loaded) CPU,
# Phase B has no excuse not to finish - every poll must return the full 16 per-core rows, never the 1-row
# fallback. This is what actually catches a per-core regression (the property f619829 fixed), now isolated from
# the saturation tolerance above instead of conflated with it.
# GH CI finding: this guard FAILED (n_bad=2/5) on a real 2-vCPU runner with NO saturation at all - a genuine
# product signal (per-core stats dropping out too often on small/slow boxes), not a test artifact. Per-poll
# phase timings below (Phase A, backends curl, the merged naff/threads/validate jq, bloxsense, rows+compose,
# write) are printed COMPACTLY for every poll, pass or fail, from this file's own existing dbg() timestamps -
# no new instrumentation added to h-stats.sh itself, just parsed out of what it already logs - so CI shows
# where time actually goes on whatever runner hits this, not just a bare pass/fail.
print_phase_timings() {   # $1 = debug log path; prints one compact "phaseA=.. curl=.. jq=.. bloxsense[cached]=.. rows=.. write=.. total=.." line
	awk '
		{ ts = $1 }
		!a && /phase A: entry/ { a = ts }
		!ad && /phase A: DONE/ { ad = ts }
		!b && /phase B: entry/ { b = ts }
		!bc && /phase B: curl .*\/2\/backends/ { bc = ts }
		!nf && /phase B: naff=/ { nf = ts }
		!bs && /phase B: bloxsense rc=/ { bs = ts }
		!bs && /phase B: bloxsense SKIPPED - using cached/ { bs = ts; cached = 1 }
		!cmp && /phase B: composing final stats/ { cmp = ts }
		!ex && /run\(\) EXIT/ { ex = ts }
		END {
			out = ""
			if (a && ad) out = out sprintf("phaseA=%.3f ", ad - a); else out = out "phaseA=? "
			if (b && bc) out = out sprintf("curl=%.3f ", bc - b); else out = out "curl=? "
			if (bc && nf) out = out sprintf("jq=%.3f ", nf - bc); else out = out "jq=? "
			label = cached ? "bloxsense[cached]=" : "bloxsense="
			if (nf && bs) out = out sprintf("%s%.3f ", label, bs - nf); else out = out label "? "
			if (bs && cmp) out = out sprintf("rows=%.3f ", cmp - bs); else out = out "rows=? "
			if (cmp && ex) out = out sprintf("write=%.3f ", ex - cmp); else out = out "write=? "
			if (a && ex) out = out sprintf("total=%.3f", ex - a); else out = out "total=?"
			print out
		}
	' "$1" 2>/dev/null
}
python3 "$HERE/fake_xmrig_api.py" 4069 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
grep -q ready "$T/api.out" || bad "per-core regression guard: fake API startup" "$(cat "$T/api.out" 2>/dev/null)"
N_POLLS1B=5
n_bad1b=0
for i in $(seq 1 "$N_POLLS1B"); do
	DBG1B="$T/dbg1b_$i.log"; rm -f "$DBG1B"
	# shellcheck disable=SC2016
	res=$(BLOX_HSTATS_DEBUG_LOG="$DBG1B" timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	khs=$(jq -r '.khs' <<< "$res" 2>/dev/null)
	nrows=$(jq -r '.stats.hs | length' <<< "$res" 2>/dev/null)
	timing=$(print_phase_timings "$DBG1B")
	echo "  poll $i: $timing"
	if [[ $khs != 16.50 ]] || [[ $nrows != 16 ]]; then
		n_bad1b=$((n_bad1b+1)); echo "  poll $i: unexpected (khs=$khs rows=$nrows res=$res)"
		echo "  poll $i: --- BLOX_HSTATS_DEBUG_LOG ---"
		sed 's/^/  poll '"$i"' dbg: /' "$DBG1B" 2>/dev/null
	fi
	rm -f "$DBG1B"
done
if (( n_bad1b == 0 )); then
	ok "per-core regression guard (unloaded): khs=16.50, 16 per-core rows, every poll ($N_POLLS1B polls)"
else
	bad "per-core regression guard (unloaded): khs=16.50, 16 per-core rows, every poll" "n_bad=$n_bad1b/$N_POLLS1B"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
unset BLOX_PROCFS_ROOT

# ================================================================== case 2: REAL /proc, REAL xmrig --bench, full CPU load
XMRIG_BIN="${BLOX_XMRIG_BIN:-$HOME/bxwork/out/xmrig}"
BLOXSENSE_BIN="${BLOX_BLOXSENSE_BIN:-$HOME/bxwork/out/bloxsense}"
REQUIRE_REAL=${BLOX_REQUIRE_REAL_ENGINE:-0}
if [[ -x $XMRIG_BIN ]]; then
	# xmrig runs FROM the package dir (not a separate work dir + symlink): the ownership check compares
	# /proc/<pid>/exe (the kernel's own canonical path to what was actually exec'd) against "$PKG/xmrig" as a
	# plain string, so the binary's real, running location must be exactly that path.
	REAL_DIR="$T/pkg2"; mkdir -p "$REAL_DIR" "$T/log2"
	cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$REAL_DIR"/
	cp "$XMRIG_BIN" "$REAL_DIR/xmrig"
	if [[ -x $BLOXSENSE_BIN ]]; then
		cp "$BLOXSENSE_BIN" "$REAL_DIR/bloxsense"   # the REAL binary: genuinely real topology, temps and RAPL timing on this box
	else
		cp "$BLOX_DIR/bloxsense" "$REAL_DIR/bloxsense"   # fallback: the ~0.55 s-sleeping fixture, if bloxsense was not built
		[[ $REQUIRE_REAL == 1 ]] && bad "REAL bloxsense present (BLOX_REQUIRE_REAL_ENGINE=1)" "$BLOXSENSE_BIN not found/executable - fell back to the fixture"
	fi
	sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config2.json#" \
	    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log2/bloxminer-x#" "$PKGSRC/h-manifest.conf" > "$REAL_DIR/h-manifest.conf"
	jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config2.json"
	cat > "$REAL_DIR/xmrig-config.json" <<'CFG'
{
  "autosave": false, "background": false, "colors": false,
  "randomx": {"1gb-pages": false},
  "cpu": {"enabled": true, "huge-pages": false},
  "opencl": {"enabled": false}, "cuda": {"enabled": false},
  "http": {"enabled": true, "host": "127.0.0.1", "port": 4070, "restricted": true, "access-token": null},
  "donate-level": 0, "donate-over-proxy": 0,
  "pools": [{"url": "127.0.0.1:19999", "user": "test", "pass": "x", "algo": "rx/0", "keepalive": false}]
}
CFG
	# `exec` inside the subshell (rather than `cd ... && ./xmrig ...` as one backgrounded compound command) so
	# the subshell's own process image BECOMES xmrig - otherwise `$!` captures the wrapper bash the "cd &&"
	# chain keeps alive, not xmrig itself (a then-unknown child of it), and killing that PID later orphans the
	# real xmrig process instead of stopping it (found while writing this very test).
	( cd "$REAL_DIR" || exit 1; exec ./xmrig -c xmrig-config.json --bench=10M > console.txt 2>&1 ) &
	XMRIG_PID=$!
	# Wait until XMRig's own API reports a populated 10 s hashrate average (null/0 until RandomX dataset init -
	# ~7 s on ai02, far longer on a small CI runner - plus a full 10 s window): a fixed sleep was enough on the
	# dev box but would make this case flaky on slower hosts. Capped at 180 s; real CPU load throughout.
	warm=0; warm_deadline=$((SECONDS + 180))
	while (( SECONDS < warm_deadline )); do
		kill -0 "$XMRIG_PID" 2>/dev/null || break
		# Non-empty check in bash first: jq 1.6 (this repo's CI and real rigs) exits 0 for `-e` on EMPTY input,
		# which is exactly what curl yields before xmrig's API is up - that would end the wait instantly.
		sum=$(curl -s --max-time 2 http://127.0.0.1:4070/2/summary)
		[[ -n $sum ]] && jq -e '.hashrate.total[0] | type == "number" and . > 0' >/dev/null 2>&1 <<< "$sum" && { warm=1; break; }
		sleep 1
	done
	(( warm )) || echo "  (xmrig hashrate[0] still unpopulated after warm-up; polling anyway - the assertion below decides)"

	export BLOX_DIR="$REAL_DIR" BLOX_API_PORT=4070
	unset BLOX_PROCFS_ROOT   # the REAL /proc this time - whatever this box's real process table looks like
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	khs=$(jq -r '.khs' <<< "$res" 2>/dev/null)
	nrows=$(jq -r '.stats.hs | length' <<< "$res" 2>/dev/null)
	if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && awk -v k="${khs:-0}" 'BEGIN{exit !(k > 0)}' && [[ ${nrows:-0} -gt 0 ]]; then
		ok "REAL xmrig --bench under full CPU load: khs=$khs, $nrows rows, < 3.0 s (${elapsed}s)"
	else
		bad "REAL xmrig --bench under full CPU load: khs > 0, rows > 0, < 3.0 s" "elapsed=${elapsed}s khs=$khs rows=$nrows res=$res"
		echo "  --- xmrig console (last 40 lines) ---"; tail -n 40 "$REAL_DIR/console.txt" 2>/dev/null | sed 's/^/  /'
	fi
	kill -9 "$XMRIG_PID" 2>/dev/null; wait "$XMRIG_PID" 2>/dev/null; XMRIG_PID=""
elif [[ $REQUIRE_REAL == 1 ]]; then
	bad "REAL xmrig bench case (BLOX_REQUIRE_REAL_ENGINE=1)" "$XMRIG_BIN not found/executable"
else
	echo "SKIP: real xmrig bench case ($XMRIG_BIN not found - build it first with build/build.sh)"
fi

# ================================================================== case 3: sustained polling (60 polls) under
# full CPU load, plus 1/2/3-CPU taskset tiers - the same fake-/proc fixture as case 1, but sourced repeatedly
# (Hive's real agent does exactly this, poll after poll, in the SAME shell) rather than once. Proves the result
# stays well-formed and bounded across many polls, not just a single lucky one, and that a smaller cpuset
# (fewer cores than this host has, closer to a constrained CI runner) does not reintroduce false zeros or
# budget overruns. HARD_CAP is budget (3.0 s) + a generous fixed 1.0 s tolerance for legitimate scheduling
# jitter, never relaxed by the statistical (90%) tolerance below - a single poll running arbitrarily long is a
# real regression even if every other poll in the run stayed well inside budget.
API3_PID=""; API3B_PID=""
cleanup3() {
	[[ -n $API3_PID ]] && { kill "$API3_PID" 2>/dev/null; wait "$API3_PID" 2>/dev/null; }
	[[ -n $API3B_PID ]] && { kill "$API3B_PID" 2>/dev/null; wait "$API3B_PID" 2>/dev/null; }
	stop_saturating
}
trap 'cleanup; cleanup3' EXIT

jq -n --argjson s "$SUM_OK" --argjson b "$BACK_OK" '{summary: $s, backends: $b}' > "$T/replies3.json"
: > "$T/api3.out"
python3 "$HERE/fake_xmrig_api.py" 4069 "$T/replies3.json" > "$T/api3.out" 2>&1 & API3_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api3.out" && break; sleep 0.1; done
grep -q ready "$T/api3.out" || bad "sustained polling: fake API startup" "$(cat "$T/api3.out" 2>/dev/null)"
for _ in $(seq 20); do curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:4069/2/summary" && break; sleep 0.05; done

# BLOX_DIR explicitly reset to case 1's own fixture dir ("$T/pkg", matching $PROC's own exe symlink target) -
# case 2 above may have repointed it at "$T/pkg2" (the REAL xmrig dir) if a frozen build was found there, which
# would make every poll here fail ownership against this case's own fake $PROC fixture.
export BLOX_DIR="$T/pkg" BLOX_PROCFS_ROOT="$PROC" BLOX_API_PORT=4069
saturate_cpus
sleep 0.3
N_POLLS=60
HARD_CAP=4.0
n_zero=0; n_over_budget=0; n_hardfail=0; max_elapsed=0
# ---- CI diagnostics (GitHub Actions hit a real 5.01 s hard-cap breach + false-zero on this exact case, twice,
# that ai02 cannot reproduce under any load/taskset combination tried - so reason from a trace instead of
# guessing further). Every poll gets its own BLOX_HSTATS_DEBUG_LOG (run()'s own dbg() timestamps, already
# built into h-stats.sh) and its own `set -x` trace (PS4 timestamped via EPOCHREALTIME, BASH_XTRACEFD so it
# never mixes into the poll's own stdout/stderr capture) of the WHOLE sourced call, not just run() - covering
# every parent-side step too (mktemp, ps, the result read-back, the final jq parse - none of which carry their
# own per-step timeout the way run()'s own child-side steps do). A watchdog checks, WITHOUT blocking the outer
# `timeout 5` itself, whether the poll is still alive at ~4.6 s (before that external timeout can fire) and
# dumps `ps` for the WHOLE system at that instant if so - the one piece of evidence that would show exactly
# which process is still running and in what state (D/S/Z, wchan) the moment everything gets killed. Logs for
# a PASSING poll are deleted immediately (kept quiet, bounded disk use over 60 polls); a HARDFAIL or ZERO poll
# dumps its full debug log, its last ~150 trace lines, and any watchdog ps dump straight into this test's own
# output, so the next CI failure carries the trace instead of just the bare numbers.
for i in $(seq 1 "$N_POLLS"); do
	DBGLOG="$T/dbg_poll_$i.log"; TRACELOG="$T/trace_poll_$i.log"; PSLOG="$T/ps_poll_$i.log"; OUTLOG="$T/out_poll_$i.log"
	rm -f "$DBGLOG" "$TRACELOG" "$PSLOG" "$OUTLOG"
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016   # $BLOX_DIR/$khs/$tfd/$BASH_SOURCE/$LINENO are meant to expand in the INNER
	# bash -c (at trace time, or via that shell's own env), never here - the one exception is $TRACELOG, which
	# must be the OUTER (per-poll) path, so it is deliberately closed out of the single-quoted string instead.
	BLOX_HSTATS_DEBUG_LOG="$DBGLOG" timeout 5 bash -c '
		exec {tfd}>"'"$TRACELOG"'"
		export BASH_XTRACEFD=$tfd
		PS4="+ ${EPOCHREALTIME:-?} ${BASH_SOURCE##*/}:${LINENO}: "
		set -x
		. "$BLOX_DIR/h-stats.sh"
		set +x
		echo "khs=[$khs]"
	' > "$OUTLOG" 2>&1 &
	POLL_PID=$!
	watchdog_fired=0
	for w in $(seq 1 28); do   # 28 x 0.2 s = 5.6 s - a backstop past the inner `timeout 5` itself, never relied
		kill -0 "$POLL_PID" 2>/dev/null || break                       # on to actually bound anything by itself
		if [[ $w -eq 23 && $watchdog_fired == 0 ]]; then   # ~4.6 s - before the inner timeout's own 5.0 s fires
			watchdog_fired=1
			{
				echo "WATCHDOG: poll $i still running at ~${w}x0.2s, dumping ps"
				# Filtered to this poll's own candidate processes, never the whole system table - a real run
				# has hundreds of unrelated kernel threads/services that would otherwise bury the one thing
				# this exists to show. The header line always matches "CMD" too, so it survives the filter.
				# shellcheck disable=SC2009   # pgrep cannot report stat/wchan/etime together - that is the
				# whole point of this dump, not something pgrep -a or an equivalent could replace here.
				# Deliberately NOT a bare "bash" term: on a shared/busy host (CI runners are not, but ai02 is)
				# that alone matches every unrelated bash process system-wide - "h-stats.sh" alone is enough
				# to catch the actual wrapper, since its own cmdline embeds the whole sourced script's path.
				ps -eo pid,ppid,pgid,stat,wchan:20,etime,cmd 2>/dev/null | grep -iE 'CMD|h-stats|curl|bloxsense|xmrig|mktemp|awk|find|timeout|readlink|jq|ps -eo'
			} > "$PSLOG" 2>&1
		fi
		sleep 0.2
	done
	wait "$POLL_PID" 2>/dev/null
	t1=$(date +%s.%N)
	res=$(cat "$OUTLOG" 2>/dev/null)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
	poll_bad=0
	awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_zero=$((n_zero+1)); poll_bad=1; echo "  poll $i: ZERO khs ($res)"; }
	awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' || { n_over_budget=$((n_over_budget+1)); echo "  poll $i: OVER BUDGET (${elapsed}s)"; }
	awk -v e="$elapsed" -v c="$HARD_CAP" 'BEGIN{exit !(e > c)}' && { n_hardfail=$((n_hardfail+1)); poll_bad=1; echo "  poll $i: HARD CAP EXCEEDED (${elapsed}s > ${HARD_CAP}s)"; }
	awk -v e="$elapsed" -v m="$max_elapsed" 'BEGIN{exit !(e > m)}' && max_elapsed=$elapsed
	if (( poll_bad )); then
		echo "  poll $i: --- BLOX_HSTATS_DEBUG_LOG ---"
		sed 's/^/  poll '"$i"' dbg: /' "$DBGLOG" 2>/dev/null
		echo "  poll $i: --- last ~150 trace lines ---"
		tail -n 150 "$TRACELOG" 2>/dev/null | sed 's/^/  poll '"$i"' trace: /'
		if [[ -s $PSLOG ]]; then
			echo "  poll $i: --- watchdog ps dump (~4.6s) ---"
			sed 's/^/  poll '"$i"' ps: /' "$PSLOG"
		fi
	fi
	rm -f "$DBGLOG" "$TRACELOG" "$PSLOG" "$OUTLOG"
done
stop_saturating
n_ok_budget=$((N_POLLS - n_over_budget)); n_need_budget=$(( (N_POLLS * 9 + 9) / 10 ))
if [[ $n_zero == 0 && $n_hardfail == 0 ]] && (( n_ok_budget >= n_need_budget )); then
	ok "sustained polling ($N_POLLS polls, full CPU load): no false zeros, $n_ok_budget/$N_POLLS under 3.0 s (need >= $n_need_budget/$N_POLLS, max ${max_elapsed}s)"
else
	bad "sustained polling ($N_POLLS polls): no false zeros, $n_ok_budget/$N_POLLS under budget (need >= $n_need_budget/$N_POLLS), 0 hard-cap failures" "n_zero=$n_zero n_over_budget=$n_over_budget n_hardfail=$n_hardfail max=${max_elapsed}s"
fi

# A DEDICATED, lighter fixture for the taskset tiers below - never the sustained-polling loop's own ~1500-fd/
# 375-process $PROC or its real, ~0.55 s-sleeping bloxsense: that scan size and sensor latency are each their
# own, already-proven property (above, and in test_hive_scripts.sh's own "budget: slow bloxsense" case).
# Stacking BOTH of them on TOP OF a 1-core taskset pin AND full-nproc saturation is a strictly harder
# combination than any real rig's own worst case (an actual low-core rig is not also fighting every other core
# on the SAME box for scheduling time to run h-stats.sh's own collector child) - that specific triple
# combination was measured to genuinely exhaust the full 2.4 s collector budget before Phase A's own cheap curl
# ever gets scheduled, a real result of extreme, unrealistic starvation, not a bug in the collector itself.
# This fixture isolates "does a reduced CPU count alone, with a realistic (small) process table and an instant
# sensor reply, cause false zeros" - the property this section actually exists to prove.
BLOX_DIR3="$T/pkg3"; mkdir -p "$BLOX_DIR3" "$T/log3"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR3"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config3.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log3/bloxminer-x#" "$PKGSRC/h-manifest.conf" > "$BLOX_DIR3/h-manifest.conf"
jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config3.json"
: > "$BLOX_DIR3/xmrig"; chmod +x "$BLOX_DIR3/xmrig"
cat > "$BLOX_DIR3/bloxsense" <<'EOF'
#!/bin/sh
echo '{"cpus":[],"pkg_temp":65,"power_w":null,"ccd_reason":"test fixture"}'
EOF
chmod +x "$BLOX_DIR3/bloxsense"

PROC3="$T/proc3"
python3 - "$PROC3" "$BLOX_DIR3/xmrig" <<'PY'
import os, sys
root, xmrig_path = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(root, "net"), exist_ok=True)
TARGET_PID = "9301"
TARGET_INODE = 777777
fddir = os.path.join(root, TARGET_PID, "fd")
os.makedirs(fddir, exist_ok=True)
os.symlink("socket:[%d]" % TARGET_INODE, os.path.join(fddir, "23"))
os.symlink(xmrig_path, os.path.join(root, TARGET_PID, "exe"))
taskdir = os.path.join(root, TARGET_PID, "task")
for c in range(4):
	d = os.path.join(taskdir, str(c))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t%d\n" % c)
hexport = "%04X" % 4072
with open(os.path.join(root, "net", "tcp"), "w") as f:
	f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n")
	f.write("   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 100 0 0 10 0\n" % (hexport, TARGET_INODE))
PY
# hashrate.total[0] = 2006 (H/s): sum of BACK3's own 4 per-thread rates below (500+c for c in 0..3) - same
# realism rationale as SUM_OK above.
SUM3=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0", hashrate: {total: [2006.0]}}')
BACK3=$(python3 -c '
import json
threads = [{"affinity": c, "hashrate": [500.0 + c, None, None]} for c in range(4)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
')
jq -n --argjson s "$SUM3" --argjson b "$BACK3" '{summary: $s, backends: $b}' > "$T/replies3b.json"
: > "$T/api3b.out"
python3 "$HERE/fake_xmrig_api.py" 4072 "$T/replies3b.json" > "$T/api3b.out" 2>&1 & API3B_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api3b.out" && break; sleep 0.1; done
grep -q ready "$T/api3b.out" || bad "taskset tiers: fake API startup" "$(cat "$T/api3b.out" 2>/dev/null)"
for _ in $(seq 20); do curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:4072/2/summary" && break; sleep 0.05; done
export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4072

if command -v taskset > /dev/null 2>&1; then
	DISP_N=5
	for want in 1 2 3; do
		if ! first_n_cpus "$want"; then
			echo "SKIP: taskset tier $want CPU(s) - only ${#AVAIL_CPUS[@]} CPU(s) available to this process"
			continue
		fi
		cpulist=$REPLY
		eb=1; (( want < 3 )) && eb=0   # budget enforced from 3 CPUs up only - 1-2 CPU tiers are a pure liveness
			# check (no false zeros, no hard-cap overrun), no timing claim - the same policy BloxMiner v3's own
			# load tests use, since scheduling jitter at the most extreme tiers is not a real regression signal.
		HARD_CAP_D=4.5
		saturate_tier "$want"; sleep 0.3
		n_zero_d=0; n_over_d=0; n_hardfail_d=0; max_d=0
		for _ in $(seq 1 "$DISP_N"); do
			t0=$(date +%s.%N)
			# shellcheck disable=SC2016
			res=$(timeout 5 taskset -c "$cpulist" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
			t1=$(date +%s.%N)
			elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
			pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
			awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || n_zero_d=$((n_zero_d+1))
			awk -v e="$elapsed" 'BEGIN{exit !(e < 3.5)}' || n_over_d=$((n_over_d+1))
			(( eb )) && { awk -v e="$elapsed" -v c="$HARD_CAP_D" 'BEGIN{exit !(e > c)}' && n_hardfail_d=$((n_hardfail_d+1)); }
			awk -v e="$elapsed" -v m="$max_d" 'BEGIN{exit !(e > m)}' && max_d=$elapsed
		done
		stop_saturating
		n_ok_d=$((DISP_N - n_over_d)); n_need_d=$(( (DISP_N * 9 + 9) / 10 ))
		if [[ $n_zero_d == 0 && $n_hardfail_d == 0 ]] && (( ! eb || n_ok_d >= n_need_d )); then
			ok "h-stats.sh, taskset $cpulist ($want CPU(s)): no false zeros$( ((eb)) && echo ", $n_ok_d/$DISP_N < 3.5s (need >= $n_need_d/$DISP_N)" ) (max ${max_d}s)"
		else
			bad "h-stats.sh, taskset $cpulist ($want CPU(s)): no false zeros$( ((eb)) && echo ", $n_ok_d/$DISP_N under budget (need >= $n_need_d/$DISP_N), 0 hard-cap failures" )" \
				"n_zero=$n_zero_d n_over=$n_over_d n_hardfail=$n_hardfail_d max=${max_d}s"
		fi
	done
else
	echo "SKIP: taskset not available - stressed-cpuset case skipped"
fi

kill "$API3_PID" "${API3B_PID:-}" 2>/dev/null; wait "$API3_PID" "${API3B_PID:-}" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT

# ================================================================== case 4: Phase A cheap-publish under a late
# summary - the bot-review finding that if /2/summary answers near the end of the budget on a saturated CPU,
# the reserve covering the work still needed AFTER curl returns might not be enough, killing the child before
# Phase A ever publishes (a false zero indistinguishable, from Hive's side, from a genuinely dead miner).
# Reuses case 3's own dedicated light fixture (BLOX_DIR3/PROC3, port 4072's /proc layout, already killed its
# own API3B server above) - only the API server differs here (a fixed response delay added), everything else
# about the fixture's shape is the same already-justified "realistic, not artificially heavy" choice made above.
#
# DELAY4 = D, the GUARANTEED-PUBLISH WINDOW under single-CPU saturation - DERIVED, not a guessed/picked constant
# (a bot-review finding on a sibling package: a fixed ~1.85 s spec failed 20/20 on a slow GitHub runner, because
# the delay is measured from when the request is SENT, which is AFTER the parent's own start-up work - on a
# slow/contended vCPU that start-up alone can eat into the budget "by construction", regardless of how generous
# the post-curl reserve is). A second bot-review round (its own sandbox - slower than GitHub's own runner) found
# even the x2/0.1s version of this formula too tight once PHASE_A_CURL_RESERVE_US was itself resized - widened
# to a x4 start-up factor and a 0.2s margin:
#   D = budget - (measured start-up x4) - reserve - 0.2s
# "measured start-up" = poll-entry -> summary-request-sent, i.e. EVERYTHING before the mandatory curl is even
# issued (manifest sourcing, the algo jq parse, the TMPD mktemp -d, writing $LIB, the setsid child's own launch,
# and the ownership /proc scan inside it) - measured with a standalone harness, taskset -c 0 + saturate_tier(1)
# (the SAME K=4-oversubscribed single-CPU scenario this case itself runs under), 30 iterations: max 207 ms on
# ai02 (a figure that has already shown real variance run-to-run under ambient host contention - see
# PHASE_A_CURL_RESERVE_US's own header for the granular per-phase breakdown this was decomposed into). x4,
# not x2: margin against start-up being slower than this ONE sample happened to catch on THIS ONE host, given
# the bot's own sandbox and GitHub's runner have both already shown slower start-up than ai02's own baseline.
#   D = 2.4 - (0.207 * 4) - 0.1 - 0.2 = 1.272s -> 1.2s (rounded down).
# reserve = 0.1s: PHASE_A_CURL_RESERVE_US's own new value (see its header) - resized down from 0.3s once the
# post-curl fork count it has to cover dropped from two to one; this test's own D formula must always track
# that constant, never assume a value independently of it.
DELAY4=1.2
API4_PID=""
cleanup4() { [[ -n $API4_PID ]] && { kill "$API4_PID" 2>/dev/null; wait "$API4_PID" 2>/dev/null; }; stop_saturating; }
trap 'cleanup; cleanup3; cleanup4' EXIT
# Reuses $SUM3 as-is (not a separate fixture): now that SUM3 carries a realistic hashrate.total consistent with
# BACK3's own per-thread sum (see SUM3's own definition above), Phase A's OWN total here is both nonzero AND
# realistic, which is what THIS test's "khs>0 every poll" assertion needs to mean something whenever Phase B
# gets skipped (exactly what the delayed summary is expected to cause, by eating most of the budget) - Phase
# A's OWN total must be the thing proven nonzero here, since that is what this finding is actually about.
jq -n --argjson s "$SUM3" --argjson b "$BACK3" --argjson d "$DELAY4" '{summary: $s, backends: $b, delay: $d}' > "$T/replies4.json"
: > "$T/api4.out"
python3 "$HERE/fake_xmrig_api.py" 4072 "$T/replies4.json" > "$T/api4.out" 2>&1 & API4_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api4.out" && break; sleep 0.1; done
grep -q ready "$T/api4.out" || bad "Phase A late-summary: fake API startup" "$(cat "$T/api4.out" 2>/dev/null)"
export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4072
if command -v taskset > /dev/null 2>&1 && first_n_cpus 1; then
	cpu0=$REPLY
	saturate_tier 1; sleep 0.3   # 1-CPU tier (taskset -c $cpu0 below) - K=4 busy loops, not nproc, see saturate_tier()
	N_POLLS4=20; HARD_CAP4=4.0
	n_zero4=0; n_hardfail4=0; max4=0
	for i in $(seq 1 "$N_POLLS4"); do
		DBGLOG4="$T/dbg4_$i.log"; rm -f "$DBGLOG4"
		t0=$(date +%s.%N)
		# shellcheck disable=SC2016   # $BLOX_DIR/$khs expand in the inner bash -c, not here
		res=$(BLOX_HSTATS_DEBUG_LOG="$DBGLOG4" timeout 5 taskset -c "$cpu0" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
		t1=$(date +%s.%N)
		elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
		pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
		poll4_bad=0
		awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_zero4=$((n_zero4+1)); poll4_bad=1; echo "  poll $i: ZERO khs ($res)"; }
		awk -v e="$elapsed" -v c="$HARD_CAP4" 'BEGIN{exit !(e > c)}' && { n_hardfail4=$((n_hardfail4+1)); poll4_bad=1; echo "  poll $i: HARD CAP EXCEEDED (${elapsed}s > ${HARD_CAP4}s)"; }
		awk -v e="$elapsed" -v m="$max4" 'BEGIN{exit !(e > m)}' && max4=$elapsed
		if (( poll4_bad )); then
			echo "  poll $i: --- BLOX_HSTATS_DEBUG_LOG ---"
			sed 's/^/  poll '"$i"' dbg: /' "$DBGLOG4" 2>/dev/null
		fi
		rm -f "$DBGLOG4"
	done
	stop_saturating
	if [[ $n_zero4 == 0 && $n_hardfail4 == 0 ]]; then
		ok "Phase A cheap-publish: summary delayed ${DELAY4}s, pinned+saturated CPU $cpu0, $N_POLLS4 polls -> khs>0 every poll, max ${max4}s"
	else
		bad "Phase A cheap-publish: summary delayed ${DELAY4}s, pinned+saturated CPU $cpu0, $N_POLLS4 polls -> khs>0 every poll" \
			"n_zero=$n_zero4 n_hardfail=$n_hardfail4 max=${max4}s"
	fi
else
	echo "SKIP: taskset unavailable or no CPU available to this process - Phase A late-summary case skipped"
fi
kill "$API4_PID" 2>/dev/null; wait "$API4_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT

# ================================================================== case 4b: summary delayed past the WHOLE
# budget - not "close to the edge" (case 4, above) but past it outright. The collector must still come back
# within the hard cap, with a bounded, honest 0 - never a hang, and never anything resembling case 4's healthy
# result. Same light fixture (BLOX_DIR3/PROC3), own port + own (much longer) delay.
API4B_PID=""
cleanup4b() { [[ -n $API4B_PID ]] && { kill "$API4B_PID" 2>/dev/null; wait "$API4B_PID" 2>/dev/null; }; stop_saturating; }
trap 'cleanup; cleanup3; cleanup4; cleanup4b' EXIT
DELAY4B=10   # comfortably longer than BUDGET_US (2.4s) + KILL_GRACE (0.3s) + this suite's own HARD_CAP4 (4.0s)
jq -n --argjson s "$SUM3" --argjson b "$BACK3" --argjson d "$DELAY4B" '{summary: $s, backends: $b, delay: $d}' > "$T/replies4b.json"
: > "$T/api4b.out"
python3 "$HERE/fake_xmrig_api.py" 4072 "$T/replies4b.json" > "$T/api4b.out" 2>&1 & API4B_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api4b.out" && break; sleep 0.1; done
grep -q ready "$T/api4b.out" || bad "Phase A delay > budget: fake API startup" "$(cat "$T/api4b.out" 2>/dev/null)"
# Port 4072, same as case 4 above (not a new one): PROC3's /proc/net/tcp fixture (built once, earlier in this
# file) hardcodes that single listening port - case 4's own API server was already killed before this one
# starts, so reusing it here is safe and avoids yet another fixture rebuild for no benefit.
export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4072
if command -v taskset > /dev/null 2>&1 && first_n_cpus 1; then
	cpu0=$REPLY
	saturate_tier 1; sleep 0.3
	N_POLLS4B=5; HARD_CAP4B=4.0
	n_bad4b=0; max4b=0
	for i in $(seq 1 "$N_POLLS4B"); do
		t0=$(date +%s.%N)
		# shellcheck disable=SC2016   # $BLOX_DIR/$khs expand in the inner bash -c, not here
		res=$(timeout 5 taskset -c "$cpu0" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
		t1=$(date +%s.%N)
		elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
		pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
		# Must be the literal fallback "0" (no answer ever arrived in time), not Phase A's own formatted "0.00"
		# (a real, parsed, honest zero) - and bounded within the hard cap, never longer.
		if [[ $pkhs != 0 ]] || awk -v e="$elapsed" -v c="$HARD_CAP4B" 'BEGIN{exit !(e > c)}'; then
			n_bad4b=$((n_bad4b+1)); echo "  poll $i: unexpected ($res, ${elapsed}s)"
		fi
		awk -v e="$elapsed" -v m="$max4b" 'BEGIN{exit !(e > m)}' && max4b=$elapsed
	done
	stop_saturating
	if (( n_bad4b == 0 )); then
		ok "Phase A: summary delayed ${DELAY4B}s (past the whole budget) -> bounded honest 0, max ${max4b}s"
	else
		bad "Phase A: summary delayed ${DELAY4B}s (past the whole budget) -> bounded honest 0" "n_bad=$n_bad4b max=${max4b}s"
	fi
else
	echo "SKIP: taskset unavailable or no CPU available to this process - Phase A delay>budget case skipped"
fi
kill "$API4B_PID" 2>/dev/null; wait "$API4B_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT

# ================================================================== case 4c: the genuine early-startup moment -
# summary.hashrate.total null/0 AND backends threads null (no pool job assigned yet) - the ONE real-XMRig shape
# where Phase A's own 0 is the honest answer, not a bug (a bot-review finding: an UNREALISTIC fixture earlier in
# this file, summary total 0 while threads were healthy and non-null - a shape no real rig can produce - made
# this honest case indistinguishable from a false zero once Phase B ran out of time; see SUM_OK/SUM3 above).
# Distinguished from case 4b's fallback "0" by format: this is Phase A's own %.2f-formatted "0.00", a real
# parsed answer, never the bare "0" literal fallback() uses when nothing was collected at all.
API4C_PID=""
cleanup4c() { [[ -n $API4C_PID ]] && { kill "$API4C_PID" 2>/dev/null; wait "$API4C_PID" 2>/dev/null; }; stop_saturating; }
trap 'cleanup; cleanup3; cleanup4; cleanup4b; cleanup4c' EXIT
SUM_STARTUP=$(jq -nc '{uptime: 0, connection: {accepted: 0, rejected: 0}, algo: "rx/0", version: "6.26.0", hashrate: {total: [null]}}')
BACK_STARTUP='[{"type":"cpu","threads":null}]'
jq -n --argjson s "$SUM_STARTUP" --argjson b "$BACK_STARTUP" '{summary: $s, backends: $b}' > "$T/replies4c.json"
: > "$T/api4c.out"
python3 "$HERE/fake_xmrig_api.py" 4072 "$T/replies4c.json" > "$T/api4c.out" 2>&1 & API4C_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api4c.out" && break; sleep 0.1; done
grep -q ready "$T/api4c.out" || bad "startup case: fake API startup" "$(cat "$T/api4c.out" 2>/dev/null)"
export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4072   # same port 4072 - see case 4b's own comment above
if command -v taskset > /dev/null 2>&1 && first_n_cpus 1; then
	cpu0=$REPLY
	saturate_tier 1; sleep 0.3
	N_POLLS4C=5
	n_bad4c=0
	for i in $(seq 1 "$N_POLLS4C"); do
		# shellcheck disable=SC2016   # $BLOX_DIR/$khs expand in the inner bash -c, not here
		res=$(timeout 5 taskset -c "$cpu0" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
		pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
		[[ $pkhs == 0.00 ]] || { n_bad4c=$((n_bad4c+1)); echo "  poll $i: unexpected ($res)"; }
	done
	stop_saturating
	if (( n_bad4c == 0 )); then
		ok "startup case: summary total null, threads null -> honest Phase A 0.00, not a false zero"
	else
		bad "startup case: summary total null, threads null -> honest Phase A 0.00, not a false zero" "n_bad=$n_bad4c"
	fi
else
	echo "SKIP: taskset unavailable or no CPU available to this process - startup case skipped"
fi
kill "$API4C_PID" 2>/dev/null; wait "$API4C_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT

# ================================================================== case 4d: WAITFIFO regression - the parent's
# own bounded wait (wait_secs(), via `read -t 0.05 -u $waitfd`) must never hang even when the collector child
# exits WHILE that read is in progress. A bot-review P1 (real GH CI, 2-vCPU): a poll where the read was entered
# ~50ms before the child's own exit - almost exactly when the read's own timeout and the exit were due to land
# together - never returned at all; the external `timeout 5` had to kill the whole run at 5.14s. Many FAST,
# healthy polls back-to-back (no artificial delay) each complete in well under a second but still take long
# enough to pass through a handful of the poll loop's own 50ms wait_secs() ticks - across enough iterations,
# naturally-varying poll-to-poll jitter lands the child's own exit at many different phase offsets relative to
# those ticks, including right on top of one, without needing to engineer the exact timing by hand. Every poll
# must stay well inside the hard cap - on 0910fd3 (the old <(:) -based wait, before this fix) this is exactly
# the condition the bot's CI trace caught; on the WAITFIFO-based wait this replaces it with, nothing should
# ever come close, since EOF unblocks the read independently of whatever its own -t timeout does.
API4D_PID=""
cleanup4d() { [[ -n $API4D_PID ]] && { kill "$API4D_PID" 2>/dev/null; wait "$API4D_PID" 2>/dev/null; }; stop_saturating; }
trap 'cleanup; cleanup3; cleanup4; cleanup4b; cleanup4c; cleanup4d' EXIT
DELAY4D=0.13   # deliberately NOT a clean multiple of the poll loop's own 50ms tick - see the case's own header
jq -n --argjson s "$SUM3" --argjson b "$BACK3" --argjson d "$DELAY4D" '{summary: $s, backends: $b, delay: $d}' > "$T/replies4d.json"
: > "$T/api4d.out"
python3 "$HERE/fake_xmrig_api.py" 4072 "$T/replies4d.json" > "$T/api4d.out" 2>&1 & API4D_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api4d.out" && break; sleep 0.1; done
grep -q ready "$T/api4d.out" || bad "WAITFIFO regression: fake API startup" "$(cat "$T/api4d.out" 2>/dev/null)"
export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4072
N_POLLS4D=100; HARD_CAP4D=4.0
n_bad4d=0; max4d=0
for i in $(seq 1 "$N_POLLS4D"); do
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016   # $BLOX_DIR/$khs expand in the inner bash -c, not here
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
	awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_bad4d=$((n_bad4d+1)); echo "  poll $i: ZERO khs ($res)"; }
	awk -v e="$elapsed" -v c="$HARD_CAP4D" 'BEGIN{exit !(e > c)}' && { n_bad4d=$((n_bad4d+1)); echo "  poll $i: HARD CAP EXCEEDED (${elapsed}s > ${HARD_CAP4D}s)"; }
	awk -v e="$elapsed" -v m="$max4d" 'BEGIN{exit !(e > m)}' && max4d=$elapsed
done
if (( n_bad4d == 0 )); then
	ok "WAITFIFO regression: $N_POLLS4D fast back-to-back polls, child exit races the poll loop's own wait - no hang, max ${max4d}s"
else
	bad "WAITFIFO regression: $N_POLLS4D fast back-to-back polls, child exit races the poll loop's own wait - no hang" \
		"n_bad=$n_bad4d/$N_POLLS4D max=${max4d}s"
fi
kill "$API4D_PID" 2>/dev/null; wait "$API4D_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT

# ================================================================== case 4e: WATCHDOG overhead on the NORMAL
# (healthy, instant-reply, no escalation) path - the WATCHDOG adds one extra fork (itself) plus two further,
# sequential forks of its own (`sleep`, never both alive at once) to EVERY poll, win or lose, not just the
# escalated ones case 4d/test_hive_scripts.sh's own SIGTERM-ignoring cases already cover - this is the
# overhead's cost on the common case, where it is pure bookkeeping that should never be visible in the result.
# Reuses case 4d's own fixture (BLOX_DIR3/PROC3, port 4072, SUM3/BACK3 - instant, no delay/escalation anywhere
# in this path) for a healthy, fast baseline; 20 polls, each its own fresh `bash -c` process (this file's own
# established per-poll pattern elsewhere), average AND max reported explicitly so a before/after comparison
# against a pre-WATCHDOG checkout is just a diff of two log lines, not a re-run with different instrumentation.
jq -n --argjson s "$SUM3" --argjson b "$BACK3" '{summary: $s, backends: $b}' > "$T/replies4e.json"
: > "$T/api4e.out"
python3 "$HERE/fake_xmrig_api.py" 4072 "$T/replies4e.json" > "$T/api4e.out" 2>&1 & API4E_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api4e.out" && break; sleep 0.1; done
grep -q ready "$T/api4e.out" || bad "WATCHDOG overhead: fake API startup" "$(cat "$T/api4e.out" 2>/dev/null)"
export BLOX_DIR="$BLOX_DIR3" BLOX_PROCFS_ROOT="$PROC3" BLOX_API_PORT=4072
N_POLLS4E=20; HARD_CAP4E=3.0
n_bad4e=0; max4e=0; sum4e=0
for i in $(seq 1 "$N_POLLS4E"); do
	t0=$(date +%s.%N)
	# shellcheck disable=SC2016   # $BLOX_DIR/$khs expand in the inner bash -c, not here
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b - a}')
	pkhs=$(sed -n 's/^khs=\[\(.*\)\]$/\1/p' <<< "$res")
	awk -v k="${pkhs:-0}" 'BEGIN{exit !(k>0)}' || { n_bad4e=$((n_bad4e+1)); echo "  poll $i: ZERO khs ($res)"; }
	awk -v e="$elapsed" -v c="$HARD_CAP4E" 'BEGIN{exit !(e > c)}' && { n_bad4e=$((n_bad4e+1)); echo "  poll $i: OVER BUDGET (${elapsed}s)"; }
	awk -v e="$elapsed" -v m="$max4e" 'BEGIN{exit !(e > m)}' && max4e=$elapsed
	sum4e=$(awk -v s="$sum4e" -v e="$elapsed" 'BEGIN{printf "%.3f", s + e}')
done
avg4e=$(awk -v s="$sum4e" -v n="$N_POLLS4E" 'BEGIN{printf "%.3f", s / n}')
if (( n_bad4e == 0 )); then
	ok "WATCHDOG overhead, normal path: $N_POLLS4E polls, avg ${avg4e}s, max ${max4e}s, all khs>0 and < ${HARD_CAP4E}s"
else
	bad "WATCHDOG overhead, normal path: $N_POLLS4E polls, all khs>0 and < ${HARD_CAP4E}s" "n_bad=$n_bad4e/$N_POLLS4E avg=${avg4e}s max=${max4e}s"
fi
kill "$API4E_PID" 2>/dev/null; wait "$API4E_PID" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT

leaked=()
for p in "$API_PID" "$API3_PID" "${API3B_PID:-}" "${API4_PID:-}" "${API4B_PID:-}" "${API4C_PID:-}" "${API4D_PID:-}" "${API4E_PID:-}"; do [[ -n $p ]] && kill -0 "$p" 2>/dev/null && leaked+=("$p"); done
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	for p in "${leaked[@]}"; do kill -9 "$p" 2>/dev/null; done
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
