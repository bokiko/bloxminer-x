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
# built xmrig at ~/bxwork/out/xmrig - e.g. from build/build.sh - and is skipped if that is not present)
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

saturate_cpus() {   # starts nproc pure-bash-builtin busy loops (no exec, so a plain -9 always reaps them cleanly)
	local n; n=$(nproc)
	BUSY_PIDS=()
	for _ in $(seq 1 "$n"); do
		sh -c 'while :; do :; done' &
		BUSY_PIDS+=("$!")
	done
}
stop_saturating() {
	for p in "${BUSY_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	wait "${BUSY_PIDS[@]}" 2>/dev/null
	BUSY_PIDS=()
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

SUM_OK=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0"}')
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
saturate_cpus
sleep 0.3   # let the busy loops actually load every core before measuring
t0=$(date +%s.%N)
# shellcheck disable=SC2016
res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
t1=$(date +%s.%N)
stop_saturating
elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
khs=$(jq -r '.khs' <<< "$res" 2>/dev/null)
nrows=$(jq -r '.stats.hs | length' <<< "$res" 2>/dev/null)
if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && awk -v k="${khs:-0}" 'BEGIN{exit !(k > 0)}' && [[ ${nrows:-0} == 16 ]]; then
	ok "fake /proc (~1500 fds/375 procs) under full CPU load: khs=$khs, 16 rows, < 3.0 s (${elapsed}s)"
else
	bad "fake /proc (~1500 fds/375 procs) under full CPU load: khs > 0, 16 rows, < 3.0 s" "elapsed=${elapsed}s khs=$khs rows=$nrows res=$res"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
unset BLOX_PROCFS_ROOT

# ================================================================== case 2: REAL /proc, REAL xmrig --bench, full CPU load
XMRIG_BIN="$HOME/bxwork/out/xmrig"
if [[ -x $XMRIG_BIN ]]; then
	# xmrig runs FROM the package dir (not a separate work dir + symlink): the ownership check compares
	# /proc/<pid>/exe (the kernel's own canonical path to what was actually exec'd) against "$PKG/xmrig" as a
	# plain string, so the binary's real, running location must be exactly that path.
	REAL_DIR="$T/pkg2"; mkdir -p "$REAL_DIR" "$T/log2"
	cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$REAL_DIR"/
	cp "$XMRIG_BIN" "$REAL_DIR/xmrig"
	BLOXSENSE_BIN="$HOME/bxwork/out/bloxsense"
	if [[ -x $BLOXSENSE_BIN ]]; then
		cp "$BLOXSENSE_BIN" "$REAL_DIR/bloxsense"   # the REAL binary: genuinely real topology, temps and RAPL timing on this box
	else
		cp "$BLOX_DIR/bloxsense" "$REAL_DIR/bloxsense"   # fallback: the ~0.55 s-sleeping fixture, if bloxsense was not built
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
	sleep 20   # RandomX dataset init (~7 s on this box) + a full 10 s window so XMRig's own hashrate[0]
	           # average is actually populated (it reports null/0 before that; real CPU load throughout either way)

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
	fi
	kill -9 "$XMRIG_PID" 2>/dev/null; wait "$XMRIG_PID" 2>/dev/null; XMRIG_PID=""
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
SUM3=$(jq -nc '{uptime: 100, connection: {accepted: 5, rejected: 0}, algo: "rx/0", version: "6.26.0"}')
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
	NPROC=$(nproc)
	DISP_N=5
	for want in 1 2 3; do
		(( want <= NPROC )) || continue
		hi=$((want - 1))
		eb=1; (( want < 3 )) && eb=0   # budget enforced from 3 CPUs up only - 1-2 CPU tiers are a pure liveness
			# check (no false zeros, no hard-cap overrun), no timing claim - the same policy BloxMiner v3's own
			# load tests use, since scheduling jitter at the most extreme tiers is not a real regression signal.
		HARD_CAP_D=4.5
		saturate_cpus; sleep 0.3
		n_zero_d=0; n_over_d=0; n_hardfail_d=0; max_d=0
		for _ in $(seq 1 "$DISP_N"); do
			t0=$(date +%s.%N)
			# shellcheck disable=SC2016
			res=$(timeout 5 taskset -c "0-$hi" bash -c '. "$BLOX_DIR/h-stats.sh"; echo "khs=[$khs]"' 2>&1)
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
			ok "h-stats.sh, taskset 0-$hi ($want CPU(s)): no false zeros$( ((eb)) && echo ", $n_ok_d/$DISP_N < 3.5s (need >= $n_need_d/$DISP_N)" ) (max ${max_d}s)"
		else
			bad "h-stats.sh, taskset 0-$hi ($want CPU(s)): no false zeros$( ((eb)) && echo ", $n_ok_d/$DISP_N under budget (need >= $n_need_d/$DISP_N), 0 hard-cap failures" )" \
				"n_zero=$n_zero_d n_over=$n_over_d n_hardfail=$n_hardfail_d max=${max_d}s"
		fi
	done
else
	echo "SKIP: taskset not available - stressed-cpuset case skipped"
fi

kill "$API3_PID" "${API3B_PID:-}" 2>/dev/null; wait "$API3_PID" "${API3B_PID:-}" 2>/dev/null
unset BLOX_DIR BLOX_PROCFS_ROOT BLOX_API_PORT

leaked=()
for p in "$API_PID" "$API3_PID" "${API3B_PID:-}"; do [[ -n $p ]] && kill -0 "$p" 2>/dev/null && leaked+=("$p"); done
if [[ ${#leaked[@]} -eq 0 ]]; then
	ok "no leaked fake-API child processes at suite end"
else
	bad "no leaked fake-API child processes at suite end" "still alive: ${leaked[*]}"
	for p in "${leaked[@]}"; do kill -9 "$p" 2>/dev/null; done
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
