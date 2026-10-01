#!/usr/bin/env bash
# Tests for bloxminer-x/h-config.sh and bloxminer-x/h-stats.sh (Linux: needs jq, curl, timeout, python3, bash).
# Usage: tests/hive/test_hive_scripts.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer-x" && pwd)
T=$(mktemp -d); trap 'kill "$API_PID" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0; API_PID=
ok()  { pass=$((pass+1)); printf '%-58s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-58s FAIL: %s\n' "$1" "$2"; }

export BLOX_DIR=$T/pkg
mkdir -p "$BLOX_DIR"
cp "$PKGSRC"/h-config.sh "$PKGSRC"/h-stats.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer-x#" "$PKGSRC/h-manifest.conf" > "$BLOX_DIR/h-manifest.conf"
mkdir -p "$T/log"   # h-run.sh creates this in production before the miner (and h-stats.sh) ever runs
CONF=$T/config.json
: > "$BLOX_DIR/xmrig"; chmod +x "$BLOX_DIR/xmrig"     # placeholder: only its path is ever compared, never run

# ================================================================== h-config.sh
hc() {  # url template pass algo extra -> runs h-config, sets $out $rc
	out=$(BLOX_SYSFS_ROOT=${BLOX_SYSFS_ROOT:-} CUSTOM_URL=$1 CUSTOM_TEMPLATE=$2 CUSTOM_PASS=$3 CUSTOM_ALGO=$4 CUSTOM_USER_CONFIG=$5 \
	      bash "$BLOX_DIR/h-config.sh" 2>&1); rc=$?
}
jqc() { jq -r "$1" "$CONF"; }
check_cfg() {   # name, jq expression that must be true
	if [[ $rc == 0 ]] && [[ $(jq -r "$2" "$CONF" 2>/dev/null) == true ]]; then ok "$1"; else bad "$1" "rc=$rc out=$out cfg=$(cat "$CONF" 2>/dev/null)"; fi
}
check_out()  { if grep -qF -- "$2" <<< "$out"; then ok "$1"; else bad "$1" "out=$out"; fi; }
check_fail() { if [[ $rc != 0 ]] && grep -qF -- "$2" <<< "$out"; then ok "$1"; else bad "$1" "rc=$rc out=$out"; fi; }

unset BLOX_SYSFS_ROOT
hc "pool.example.com:9999" "W.rig" "" "" ""
check_cfg "host:port gets stratum+tcp://" '.pools[0].url == "stratum+tcp://pool.example.com:9999"'
check_cfg "template -> user, pass defaults to x" '.pools[0].user == "W.rig" and .pools[0].pass == "x"'
check_cfg "algo defaults to rx/0" '.pools[0].algo == "rx/0"'
check_cfg "fixed keys: donate 0, local restricted API, log file, cpu enabled+huge-pages" \
	'."donate-level" == 0 and ."donate-over-proxy" == 0 and .http.enabled == true and .http.host == "127.0.0.1" and
	 .http.port == 4069 and .http.restricted == true and (.http."access-token" == null) and
	 .cpu.enabled == true and .cpu."huge-pages" == true and (."log-file" | endswith("/log/bloxminer-x.log")) and
	 .autosave == false and .background == false and .opencl.enabled == false and .cuda.enabled == false'

hc $'stratum+tcp://a:1\nstratum+tcp://b:2' "W.rig" "" "" ""
check_cfg "only the first URL line" '.pools[0].url == "stratum+tcp://a:1"'
hc "stratum+ssl://pool:1234" "W.rig" "" "" ""
check_cfg "stratum+ssl:// URL passed through as-is (XMRig parses it)" '.pools[0].url == "stratum+ssl://pool:1234"'
hc "" "W.rig" "" "" "";  check_fail "empty URL rejected" "pool URL in the flight sheet is empty"
hc "p:1" "W.rig" "mypass" "" "";  check_cfg "Pass is always the pool password" '.pools[0].pass == "mypass"'
hc "p:1" "W.rig" "" "rx/wow" "";  check_cfg "CUSTOM_ALGO rx/wow accepted" '.pools[0].algo == "rx/wow"'
for a in rx/0 rx/wow rx/arq rx/graft rx/sfx rx/yada; do
	hc "p:1" "W.rig" "" "$a" ""
	check_cfg "algo allow-list: $a" ".pools[0].algo == \"$a\""
done
hc "p:1" "W.rig" "" "cn/r" "";  check_fail "algo not in the RandomX family rejected" "Algorithm must be one of"
hc "p:1" "W.rig" "" "rx" "";    check_fail "algo rx (not rx/0) rejected" "Algorithm must be one of"

# ---- protected keys are dropped with a message; cpu.enabled (nested) too
hc "p:1" "W.rig" "" "" '"donate-level": 5, "donate-over-proxy": 1, "http": {"port": 9}, "api": {}, "autosave": true, "log-file": "/tmp/x", "background": true, "syslog": true, "opencl": {"enabled": true}, "cuda": {"enabled": true}'
check_cfg "protected keys stay fixed" \
	'."donate-level" == 0 and ."donate-over-proxy" == 0 and .http.port == 4069 and .autosave == false and
	 (."log-file" | endswith("bloxminer-x.log")) and .background == false and .syslog == false and
	 .opencl.enabled == false and .cuda.enabled == false'
check_out "protected keys reported ignored" "donate-level"
hc "p:1" "W.rig" "" "" '"cpu": {"enabled": false, "max-threads-hint": 50}'
check_cfg "cpu.enabled forced true, other cpu keys pass through" '.cpu.enabled == true and .cpu."max-threads-hint" == 50'
check_out "cpu.enabled ignored message" "cpu.enabled"
hc "p:1" "W.rig" "" "" '"cpu": {"rx": [0, 1, 2, 3]}'
check_cfg "cpu.rx passes through" '.cpu.rx == [0, 1, 2, 3]'
hc "p:1" "W.rig" "" "" '"pools": [{"url": "stratum+tcp://evil:1", "user": "x", "pass": "x", "algo": "rx/0"}]'
check_cfg "Extra config cannot replace pools[]" '(.pools | length) == 1 and .pools[0].url == "stratum+tcp://p:1"'

# ---- tls
hc "p:1" "W.rig" "" "" '"tls": true';   check_cfg "tls true -> pools[0].tls" '.pools[0].tls == true'
hc "p:1" "W.rig" "" "" '"tls": false';  check_cfg "tls false -> pools[0].tls false" '.pools[0].tls == false'
hc "p:1" "W.rig" "" "" '"tls": "yes"';  check_fail "tls non-boolean rejected" "\"tls\" must be true or false"
hc "p:1" "W.rig" "" "" '';              check_cfg "no tls key -> no pools[0].tls" '(.pools[0] | has("tls")) | not'

# ---- 1gb-pages: opt-in only, gated on >= 3 GiB free per NUMA node
T_SYS="$T/sysfs"
setnode() { mkdir -p "$T_SYS/sys/devices/system/node/node$1"; printf 'Node %s MemFree:      %s kB\n' "$1" "$2" > "$T_SYS/sys/devices/system/node/node$1/meminfo"; }
rm -rf "$T_SYS"; setnode 0 $((4 * 1024 * 1024)); setnode 1 $((5 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": true'
check_cfg "1gb-pages: both nodes >= 3 GiB -> enabled" '.randomx."1gb-pages" == true'
rm -rf "$T_SYS"; setnode 0 $((4 * 1024 * 1024)); setnode 1 $((1 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": true'
check_cfg "1gb-pages: one node short -> dropped" '(.randomx | has("1gb-pages")) | not'
check_out "1gb-pages: dropped message names the node" "1gb-pages\" ignored"
rm -rf "$T_SYS"
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": true'
check_cfg "1gb-pages: no NUMA info -> dropped" '(.randomx | has("1gb-pages")) | not'
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": false'
check_cfg "1gb-pages: false -> not set (no NUMA check needed)" '(.randomx | has("1gb-pages")) | not'
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"1gb-pages": "true"'
check_fail "1gb-pages: non-boolean rejected" "\"1gb-pages\" must be true or false"
hc "p:1" "W.rig" "" "" '"randomx": {"rdmsr": false}, "1gb-pages": true'
check_cfg "randomx object merges alongside 1gb-pages handling" '.randomx.rdmsr == false'

# ---- nested "randomx": {"1gb-pages": ...} must go through the SAME NUMA gate as the top-level key (no bypass)
rm -rf "$T_SYS"; setnode 0 $((4 * 1024 * 1024)); setnode 1 $((5 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"randomx": {"1gb-pages": true, "rdmsr": false}'
check_cfg "nested 1gb-pages: enough memory -> enabled, sibling randomx keys kept" '.randomx."1gb-pages" == true and .randomx.rdmsr == false'
rm -rf "$T_SYS"; setnode 0 $((1 * 1024 * 1024))
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"randomx": {"1gb-pages": true}'
check_cfg "nested 1gb-pages: short on memory -> dropped, cannot bypass the gate" '(.randomx | has("1gb-pages")) | not'
BLOX_SYSFS_ROOT=$T_SYS hc "p:1" "W.rig" "" "" '"randomx": {"1gb-pages": "true"}'
check_fail "nested 1gb-pages: non-boolean rejected" "\"1gb-pages\" must be true or false"

# ---- cpu.huge-pages is forced the same way cpu.enabled is - Extra config cannot turn it off
hc "p:1" "W.rig" "" "" '"cpu": {"huge-pages": false, "max-threads-hint": 8}'
check_cfg "cpu.huge-pages forced true even when Extra sets it false" '.cpu."huge-pages" == true and .cpu."max-threads-hint" == 8'
check_out "cpu.huge-pages ignored message" "cpu.huge-pages"

# ---- print-time (and other non-protected defaults) are overridable by Extra config
hc "p:1" "W.rig" "" "" '"print-time": 30'
check_cfg "Extra config print-time survives" '."print-time" == 30'
hc "p:1" "W.rig" "" "" ''
check_cfg "print-time default is 60" '."print-time" == 60'

# ---- malformed Extra config leaves the old config intact, no temp file left behind
echo '{"old":true}' > "$CONF"
hc "p:1" "W.rig" "" "" 'not json at all'
if [[ $rc != 0 && $(cat "$CONF") == '{"old":true}' ]]; then ok "bad Extra config leaves old config intact"; else bad "bad Extra config leaves old config intact" "rc=$rc $(cat "$CONF")"; fi
if ls "$T"/config.json.tmp.* > /dev/null 2>&1; then bad "no temp file left behind" "$(ls "$T")"; else ok "no temp file left behind"; fi

# ---- injection: quotes and command substitutions in every free-text field must stay literal JSON, never run
MARK="$T/pwned"
evil_user="W.rig\"; touch ${MARK}1; \""
evil_pass="x\$(touch ${MARK}2)x"
evil_extra="\"note\": \"\$(touch ${MARK}3)\`touch ${MARK}4\`\""
hc "p:1" "$evil_user" "$evil_pass" "" "$evil_extra"
expect_note="\$(touch ${MARK}3)\`touch ${MARK}4\`"
if [[ ! -e ${MARK}1 && ! -e ${MARK}2 && ! -e ${MARK}3 && ! -e ${MARK}4 ]] &&
   [[ $(jqc .pools[0].user) == "$evil_user" && $(jqc .pools[0].pass) == "$evil_pass" && $(jqc .note) == "$expect_note" ]]
then
	ok "quotes/command substitutions stay literal JSON, nothing executes"
else
	bad "quotes/command substitutions stay literal JSON, nothing executes" "rc=$rc out=$out cfg=$(cat "$CONF")"
fi
evil_url='stratum+tcp://p:1; touch '"$MARK"'5'
hc "$evil_url" "W.rig" "" "" ""
expect_url=$(tr -d '[:space:]' <<< "$evil_url")   # h-config.sh strips whitespace from the URL by design
if [[ ! -e ${MARK}5 ]] && [[ $(jqc .pools[0].url) == "$expect_url" ]]; then ok "URL with shell metacharacters stays literal"; else bad "URL with shell metacharacters stays literal" "out=$out cfg=$(cat "$CONF")"; fi

# ================================================================== h-stats.sh
jq -n '{pools: [{algo: "rx/0"}]}' > "$CONF"   # h-stats.sh reads algo from the config, independent of the h-config tests above
PROC=$T/proc
export BLOX_PROCFS_ROOT=$PROC
: > "$BLOX_DIR/bloxsense"; chmod +x "$BLOX_DIR/bloxsense"
FAKE_PID=4242

reset_proc() { rm -rf "$PROC"; mkdir -p "$PROC/net"; : > "$PROC/net/tcp"; }
listen() {   # port inode exe-target
	local hex; hex=$(printf '%04X' "$1")
	{
		echo "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
		printf '   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 %s 1 0000000000000000 100 0 0 10 0\n' "$hex" "$2"
	} > "$PROC/net/tcp"
	mkdir -p "$PROC/$FAKE_PID/fd"
	ln -sf "socket:[$2]" "$PROC/$FAKE_PID/fd/23"
	ln -sf "$3" "$PROC/$FAKE_PID/exe"
}
task() { mkdir -p "$PROC/$FAKE_PID/task/$1"; printf 'Cpus_allowed_list:\t%s\n' "$2" > "$PROC/$FAKE_PID/task/$1/status"; }
bloxsense_says() { printf '%s\n' "$1" > "$BLOX_DIR/bloxsense.json"; cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/sh
cat "$BLOX_DIR/bloxsense.json"
EOF
	chmod +x "$BLOX_DIR/bloxsense"
}

fake_topo_json() {   # $1 = number of physical cores (two threads per core, SMT: cpu i and cpu i+ncores share core i)
                      # $2 = power_w (default 95.0), may be fractional
	local n=$1 p=${2:-95.0}
	python3 - "$n" "$p" <<'PY'
import json, sys
n, p = int(sys.argv[1]), float(sys.argv[2])
cpus = []
for c in range(2 * n):
	core = c % n
	cpus.append({"cpu": c, "pkg": 0, "core": core, "temp": 55 + core, "src": "core"})
print(json.dumps({"cpus": cpus, "pkg_temp": 70, "power_w": p, "ccd_reason": "test fixture"}))
PY
}

stats_case() {   # name port summary-json backends-json-or-empty jq-assertion
	kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
	local port=$2
	if [[ -n $3 ]]; then
		jq -n --argjson s "$3" --argjson b "${4:-[]}" '{summary: $s, backends: $b}' > "$T/replies.json"
		: > "$T/api.out"
		python3 "$HERE/fake_xmrig_api.py" "$port" "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
		for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
		grep -q ready "$T/api.out" || { bad "$1" "fake API did not start: $(cat "$T/api.out")"; return; }
	fi
	export BLOX_API_PORT=$port
	local res t0 t1
	t0=$(date +%s.%N)
	res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	t1=$(date +%s.%N)
	elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b - a}')
	if [[ $(jq -r "$5" <<< "$res" 2>/dev/null) == true ]]; then ok "$1 (${elapsed}s)"; else bad "$1" "elapsed=${elapsed}s $res"; fi
}

BACK_16C32T=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [ (100 + c) * 10.0, None, None]} for c in range(32)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
SUM_OK=$(jq -nc '{uptime: 321, connection: {accepted: 15, rejected: 1}, algo: "rx/0", version: "6.26.0", donate_level: 0}')

reset_proc; listen 20001 1001 "$BLOX_DIR/xmrig"
for c in $(seq 0 31); do task "t$c" "$c"; done
task "tmgmt" "0-31"   # a management thread keeping the full mask must not confuse the multiset check
bloxsense_says "$(fake_topo_json 16)"
stats_case "per-core grouping, 16C/32T, bound and verified" 20001 "$SUM_OK" "$BACK_16C32T" \
	'(.stats.hs | length) == 16 and .stats.uptime == 321 and .stats.ar == [15, 1] and .stats.cpu_power == 95 and
	 .stats.ver == "bloxminer-x 1.0.1 (xmrig 6.26.0)" and .stats.algo == "rx/0" and
	 (.stats.hs[0] == (((100 + 0) * 10 + (100 + 16) * 10) / 1000)) and (.stats.temp[0] == 55)'

BACK_NULLS=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [None, None, None]} for c in range(4)]
threads[2]["hashrate"][0] = 5000.0
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
# Release 1.0.1: a null thread rate (hashrate[0] missing/invalid) makes that row's OWN khs null, never a
# fabricated 0 silently summed in - so a backends reply with even one null-rate thread is INCOMPLETE as a
# whole and never replaces Phase A's own fresh total (the single `/2/summary` call's own aggregate rate),
# which is exactly what protects a real, positive rate from being zeroed out by an incomplete per-core/
# per-thread breakdown. SUM_HEALTHY's own hashrate.total carries the real rate (5.00 kH/s, matching the one
# thread here that DID report a number) for Phase A to answer with on its own.
SUM_HEALTHY_5=$(jq -nc '{uptime: 321, connection: {accepted: 15, rejected: 1}, algo: "rx/0", version: "6.26.0",
	hashrate: {total: [5000, null, null]}}')
reset_proc; listen 20002 1002 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "healthy summary + backends with a null thread rate -> Phase B incomplete, Phase A's own total stands" \
	20002 "$SUM_HEALTHY_5" "$BACK_NULLS" '.khs == "5.00" and (.stats.hs | length) == 1 and .stats.hs[0] == 5'

BACK_ZERO=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [0.0, 0.0, 0.0]} for c in range(4)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20003 1003 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "all-zero hashrate -> real rows, all 0 (not the single fallback row)" 20003 "$SUM_OK" "$BACK_ZERO" \
	'(.stats.hs | length) == 4 and (.stats.hs | add) == 0 and .khs == "0.00"'

reset_proc   # nothing listening at all
stats_case "API down -> khs 0, hs [0]" 20004 "" "" '.khs == "0" and .stats.hs == [0]'

reset_proc; listen 20005 1005 "/usr/bin/xmrig"   # a foreign miner owns this port; API itself is healthy
bloxsense_says "$(fake_topo_json 4)"
stats_case "foreign listener on our port -> unavailable, never its stats" 20005 "$SUM_OK" "$BACK_NULLS" \
	'.khs == "0" and .stats.hs == [0]'

BACK_UNBOUND=$(python3 - <<'PY'
import json
threads = [{"affinity": -1, "hashrate": [3000.0, None, None]} for _ in range(4)]
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20006 1006 "$BLOX_DIR/xmrig"
bloxsense_says "$(fake_topo_json 4)"
stats_case "affinity == -1 -> per-thread rows, package temp" 20006 "$SUM_OK" "$BACK_UNBOUND" \
	'(.stats.hs | length) == 4 and (.stats.temp | unique) == [70]'

# BACK_SOME_REAL: 4 threads, all REAL non-null positive rates - deliberately NOT BACK_NULLS here, so these
# three cases exercise percore/verification structure on its own, without being confounded by the null-rate
# incompleteness behavior covered separately above.
BACK_SOME_REAL=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [r, None, None]} for c, r in zip(range(4), [1000.0, 2000.0, 1500.0, 2500.0])]
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)

reset_proc; listen 20007 1007 "$BLOX_DIR/xmrig"
task "t0" "0"; task "t1" "1"; task "t2" "2"   # thread for cpu 3 never shows a single-CPU mask: verification fails
bloxsense_says "$(fake_topo_json 4)"
stats_case "affinity not independently confirmed -> per-thread rows, package temp" 20007 "$SUM_OK" "$BACK_SOME_REAL" \
	'(.stats.hs | length) == 4 and (.stats.temp | unique) == [70]'

reset_proc; listen 20008 1008 "$BLOX_DIR/xmrig"
task "t0" "0"; task "t1" "1"; task "t2" "1"; task "t3" "3"   # cpu 1 pinned twice, cpu 2 never -> multiset mismatch
bloxsense_says "$(fake_topo_json 4)"
stats_case "duplicate task pinning -> multiset mismatch -> per-thread rows" 20008 "$SUM_OK" "$BACK_SOME_REAL" \
	'(.stats.temp | unique) == [70]'

reset_proc; listen 20009 1009 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "numeric JSON types throughout" 20009 "$SUM_OK" "$BACK_SOME_REAL" \
	'(.stats.ar | map(type) | unique) == ["number"] and (.stats.uptime | type) == "number" and
	 (.stats.hs | map(type) | unique) == ["number"] and (.khs | type) == "string" and (.khs | tonumber | type) == "number"'

reset_proc; listen 20011 1011 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4 95.5)"
stats_case "fractional power_w (95.5) is not dropped" 20011 "$SUM_OK" "$BACK_SOME_REAL" '.stats.cpu_power == 95.5'

BACK_BAD_TYPES=$(python3 - <<'PY'
import json
threads = [{"affinity": str(c), "hashrate": [1000.0, None, None]} for c in range(4)]   # affinity is a STRING
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20012 1012 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "healthy summary + malformed backends (affinity as string) -> Phase B skipped, Phase A's total stands" \
	20012 "$SUM_HEALTHY_5" "$BACK_BAD_TYPES" '.khs == "5.00" and (.stats.hs | length) == 1 and .stats.hs[0] == 5'

BACK_NO_HASHRATE_ARRAY=$(jq -nc '[{"type": "cpu", "threads": [{"affinity": 0, "hashrate": "not-an-array"}]}]')
reset_proc; listen 20013 1013 "$BLOX_DIR/xmrig"; task "t0" "0"
bloxsense_says "$(fake_topo_json 4)"
stats_case "healthy summary + malformed backends (hashrate not an array) -> Phase B skipped, Phase A's total stands" \
	20013 "$SUM_OK" "$BACK_NO_HASHRATE_ARRAY" '.khs == "0.00" and .stats.hs == [0]'

BACK_NEGATIVE=$(python3 - <<'PY'
import json
threads = [{"affinity": c, "hashrate": [1000.0, None, None]} for c in range(4)]
threads[1]["hashrate"][0] = -500.0   # one bad rate must clamp to 0, never go negative, and must not poison the others
print(json.dumps([{"type": "cpu", "threads": threads}]))
PY
)
reset_proc; listen 20014 1014 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "negative rate clamps to 0 for that row, others unaffected" 20014 "$SUM_OK" "$BACK_NEGATIVE" \
	'.stats.hs == [1, 0, 1, 1] and .khs == "3.00"'

BACK_NO_THREADS_KEY=$(jq -nc '[{"type": "cpu", "algo": null}]')   # legitimate: before the first pool job, no "threads" key at all
reset_proc; listen 20015 1015 "$BLOX_DIR/xmrig"
bloxsense_says "$(fake_topo_json 4)"
stats_case "cpu backend with no threads key yet (pre-first-job) -> hs [0], khs 0" 20015 "$SUM_OK" "$BACK_NO_THREADS_KEY" \
	'.khs == "0.00" and .stats.hs == [0]'

# ---- empty API output: the API is listening (unlike "API down" above) but answers with an empty/erroring
# body (HTTP 500 from fake_xmrig_api.py's own "null body" convention) - curl -fsS then returns empty stdout,
# which must be refused the SAME way as a genuinely malformed reply (jq 1.6's `-e` exits 0 on empty input -
# see valid_summary()/valid_backends()'s own header), never silently treated as "valid but empty".
reset_proc; listen 20031 1031 "$BLOX_DIR/xmrig"
bloxsense_says "$(fake_topo_json 4)"
stats_case "empty /2/summary body (API up, HTTP 500) -> unavailable, khs 0" 20031 "" "" '.khs == "0" and .stats.hs == [0]'
jq -n --argjson s null --argjson b null '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20031 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20031
res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
if [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "empty /2/summary body (API up, HTTP 500) -> unavailable, khs 0"
else
	bad "empty /2/summary body (API up, HTTP 500) -> unavailable, khs 0" "$res"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null

# ---- empty sensor output: a healthy summary AND healthy, complete, non-null backends, but bloxsense itself
# produces empty output (crashes silently / killed before writing anything) - Phase B must still fall back to
# its own safe default ({"cpus":[],"pkg_temp":null,"power_w":null,...}) rather than feed an empty $sense into
# the jq --argjson calls further down (a hard, fatal argument error there, not a graceful "not verified"
# outcome) - the RATE itself (fully independent of sensors) must still come through correctly.
reset_proc; listen 20032 1032 "$BLOX_DIR/xmrig"   # no tasks set up: affinity never independently confirmed,
	# so this takes the per-thread (not per-core) path regardless of the empty sensor output below
cat > "$BLOX_DIR/bloxsense" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BLOX_DIR/bloxsense"
stats_case "empty bloxsense output (healthy summary+backends) -> safe sensor default, rate still correct" \
	20032 "$SUM_OK" "$BACK_SOME_REAL" '.stats.temp == [null, null, null, null] and (.stats.hs | add) == 7'
bloxsense_says "$(fake_topo_json 4)"

# ---- inconsistent totals: Phase A's own fresh total is healthy and positive, but Phase B's own (complete,
# no nulls) total disagrees with it by far more than the 10% tolerance - treated as INCONSISTENT, never as a
# fresher answer, so Phase A's own total (the one `/2/summary` call XMRig itself just answered) stands. This is
# the false-zero class this whole split exists to prevent: a near-zero (or just very different) Phase B total
# must never quietly overrule a real, fresh, positive Phase A rate.
SUM_HEALTHY_50=$(jq -nc '{uptime: 321, connection: {accepted: 15, rejected: 1}, algo: "rx/0", version: "6.26.0",
	hashrate: {total: [50000, null, null]}}')   # 50.00 kH/s - BACK_SOME_REAL's own total (7.00 kH/s) disagrees by far more than 10%
reset_proc; listen 20033 1033 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
stats_case "healthy summary (50 kH/s) + complete but wildly disagreeing backends (7 kH/s) -> Phase A's total stands" \
	20033 "$SUM_HEALTHY_50" "$BACK_SOME_REAL" '.khs == "50.00" and (.stats.hs | length) == 1 and .stats.hs[0] == 50'
# stats_case's own cleanup-on-NEXT-call convention (kill "$API_PID" at its own entry) only fires when the NEXT
# step is ALSO a stats_case call - the next one below is a raw block instead, which never calls stats_case
# again, so this server would otherwise leak for the rest of the script (silently - different ports never
# collide, only ever noticed as a stray listener outliving this whole test run). Explicit here so every port
# gets torn down before the next one starts, never relying on what kind of step comes next.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null

# ---- failed stats composition: BLOX_HSTATS_TEST_FORCE_STATS_FAIL simulates the transient jq/fork failure
# class the composition's own validate-before-write guard exists for (see run()'s own header comment) - makes
# power_raw not valid JSON right before the final --argjson composition, so that jq call fails fatally. Phase
# A's own already-written result must be left completely untouched, never partially overwritten. $SUM_OK (no
# hashrate.total -> Phase A's own khs_fresh is 0) rather than a healthy positive summary: Phase A == 0 is
# ALWAYS treated as consistent with whatever Phase B computes (nothing positive to protect yet), so this
# reaches the composition step at all (a healthy-but-different Phase A total, e.g. 5 vs BACK_SOME_REAL's own
# 7, would be rejected by the EARLIER consistency check instead - never reaching composition, which would make
# this test pass for the wrong reason without ever actually exercising BLOX_HSTATS_TEST_FORCE_STATS_FAIL).
reset_proc; listen 20034 1034 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20034 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20034 BLOX_HSTATS_TEST_FORCE_STATS_FAIL=1 BLOX_HSTATS_DEBUG_LOG="$T/dbg34.log"
rm -f "$T/dbg34.log"
res=$(bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
unset BLOX_HSTATS_TEST_FORCE_STATS_FAIL BLOX_HSTATS_DEBUG_LOG
# Confirms the forced path was actually HIT, not just that the final result happens to look the same as if it
# had been (e.g. rejected earlier by the consistency check instead) - proves this test exercises what it claims.
if [[ $(jq -r '.khs == "0.00" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]] && grep -q "FAILED - final stats composition" "$T/dbg34.log" 2>/dev/null; then
	ok "forced stats-composition failure -> Phase A's already-written result stands untouched"
else
	bad "forced stats-composition failure -> Phase A's already-written result stands untouched" "res=$res dbg=$(cat "$T/dbg34.log" 2>/dev/null)"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null

# ---- repeated polls in one sourced shell: Hive's real agent sources h-stats.sh repeatedly in the SAME shell,
# poll after poll - $khs/$stats are plain globals, so a poll that collects nothing must never let a PREVIOUS
# poll's positive values stand as if they were this poll's own fresh answer (the top-of-file unconditional
# reset is exactly what prevents that). First poll: healthy, positive. Second poll, same shell: API now down.
reset_proc; listen 20035 1035 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
jq -n --argjson s "$SUM_HEALTHY_50" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20035 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
res=$(BLOX_API_PORT=20035 API_PID="$API_PID" bash -c '
	. "$BLOX_DIR/h-stats.sh"; khs1=$khs
	kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
	. "$BLOX_DIR/h-stats.sh"
	jq -nc --arg k1 "$khs1" --arg k2 "$khs" --arg s2 "$stats" "{khs1: \$k1, khs2: \$k2, stats2: (\$s2 | fromjson)}"
' 2>&1)
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
if [[ $(jq -r '.khs1 == "50.00" and .khs2 == "0" and .stats2.hs == [0]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "repeated polls, one sourced shell: a dead second poll never inherits the first poll's positive rate"
else
	bad "repeated polls, one sourced shell: a dead second poll never inherits the first poll's positive rate" "$res"
fi

# ---- budget: ONE shared 3.0 s deadline - a slow step gets whatever is left, never more, and the whole run
#      (ownership check + both curls + bloxsense) stays comfortably under 3.2 s wall time even in bad cases.
run_hstats_timed() {   # -> sets $res $elapsed (wall time, seconds)
	local a b
	a=$(date +%s.%N)
	# shellcheck disable=SC2016   # $BLOX_DIR/$khs/$stats are meant to expand inside the inner bash -c, not here
	res=$(timeout 5 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
	b=$(date +%s.%N)
	elapsed=$(awk -v x="$a" -v y="$b" 'BEGIN{printf "%.2f", y - x}')
}
under_budget() { awk -v e="$1" 'BEGIN{exit !(e < 3.2)}'; }

# slow bloxsense (sleeps 5 s), fast/normal API: bloxsense is killed at whatever remains of the shared budget
# (not a fixed 1.8 s), so the total still stays under 3.2 s
reset_proc; listen 20010 1010 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
cat > "$BLOX_DIR/bloxsense" <<'EOF'
#!/bin/sh
sleep 5
echo '{"cpus":[],"pkg_temp":null,"power_w":null,"ccd_reason":"slow"}'
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20010 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20010
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '(.stats.temp | unique) == [null]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: slow bloxsense capped by the remaining shared budget (${elapsed}s)"
else
	bad "budget: slow bloxsense capped by the remaining shared budget" "elapsed=${elapsed}s $res"
fi

# a hanging/very slow API (10 s reply delay, far longer than the WHOLE 2.4 s collector budget, let alone
# Phase A's own curl allowance within it): still bounded, never a hang - falls back cleanly (khs 0, hs [0])
# well under 3.2 s. See the very next case for the property this one is paired with: a DELAY LESS than the
# remaining budget must NOT be treated the same way (a healthy-but-slow API must still get its real answer).
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" --argjson d 10 '{summary: $s, backends: $b, delay: $d}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20016 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
reset_proc; listen 20016 1016 "$BLOX_DIR/xmrig"
export BLOX_API_PORT=20016
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: hanging API falls back under 3.2 s (${elapsed}s)"
else
	bad "budget: hanging API falls back under 3.2 s" "elapsed=${elapsed}s $res"
fi

# ---- P1 (bot review): Phase A's mandatory /2/summary curl used to be capped at a flat 0.5 s ceiling,
# regardless of how much of the shared 2.4 s budget actually remained - a genuinely healthy XMRig HTTP API
# under real CPU pressure (its OWN process, not just this file's) can legitimately take well over 500 ms to
# answer, and that flat ceiling killed the call anyway, reporting a false 0 with most of the budget still
# unused. A delay comfortably inside the real budget (~1.2 s, well past the OLD 0.5 s ceiling but nowhere
# close to the 2.4 s collector deadline) must now get its REAL answer, not a false zero - the fix gives this
# one mandatory call everything that remains, reserving only a small, measured amount for the parse/write
# that follow it (see h-stats.sh's own PHASE_A_CURL_RESERVE_US comment).
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
jq -n --argjson s "$SUM_HEALTHY_5" --argjson b "$BACK_NULLS" --argjson d 1.2 '{summary: $s, backends: $b, delay: $d}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20038 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
reset_proc; listen 20038 1038 "$BLOX_DIR/xmrig"
export BLOX_API_PORT=20038
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '.khs == "5.00"' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: /2/summary answering after ~1.2 s (past the OLD 0.5 s cap, inside the real budget) still gets its real total (${elapsed}s)"
else
	bad "budget: /2/summary answering after ~1.2 s still gets its real total" "elapsed=${elapsed}s $res"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null

# a LARGE /proc (thousands of fd entries, none matching, plus thousands of stale task entries) together with a
# hanging API: the /proc ownership scan and the task-mask scan are not individually timed steps - they only
# stay bounded because the ENTIRE collection runs inside one child process under `timeout`. This proves a
# pathologically large process table can never make h-stats.sh itself overrun the shared deadline.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc
python3 - "$PROC" <<'PY'
import os, sys
root = sys.argv[1]
fddir = os.path.join(root, "1017", "fd")
os.makedirs(fddir, exist_ok=True)
for i in range(6000):   # none of these match the inode below: forces a full, futile scan of all 6000 entries
	os.symlink("socket:[%d]" % (900000 + i), os.path.join(fddir, str(i)))
taskdir = os.path.join(root, "1017", "task")
for i in range(6000):
	d = os.path.join(taskdir, str(i))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t%d\n" % (i % 4))
PY
hex1017=$(printf '%04X' 20017)
{
	echo "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"
	printf '   0: 0100007F:%s 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1099 1 0000000000000000 100 0 0 10 0\n' "$hex1017"
} > "$PROC/net/tcp"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" --argjson d 10 '{summary: $s, backends: $b, delay: $d}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20017 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20017
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: huge /proc (6000 fd + 6000 tasks) + hanging API still bounded, falls back (${elapsed}s)"
else
	bad "budget: huge /proc (6000 fd + 6000 tasks) + hanging API still bounded, falls back" "elapsed=${elapsed}s $res"
fi

# a LARGE task list (6000 stale entries) with otherwise-healthy ownership and API: exercises the task-mask
# scan specifically (rather than the ownership fd-scan above) - still bounded, and always produces a
# well-formed result (either genuine per-thread rows, if the scan finishes in time, or the defined fallback).
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20018 1018 "$BLOX_DIR/xmrig"
python3 - "$PROC" <<'PY'
import os, sys
root = sys.argv[1]
taskdir = os.path.join(root, "1018", "task")
for i in range(6000):   # none of these are single-CPU masks matching our 4 real thread affinities
	d = os.path.join(taskdir, str(i))
	os.makedirs(d, exist_ok=True)
	with open(os.path.join(d, "status"), "w") as f:
		f.write("Cpus_allowed_list:\t0-31\n")
PY
bloxsense_says "$(fake_topo_json 4)"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20018 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20018
run_hstats_timed
if under_budget "$elapsed" && [[ $(jq -r '(.stats.hs | type) == "array"' <<< "$res" 2>/dev/null) == true ]]; then
	ok "budget: huge task list (6000 entries) stays bounded, well-formed result (${elapsed}s)"
else
	bad "budget: huge task list (6000 entries) stays bounded, well-formed result" "elapsed=${elapsed}s $res"
fi
bloxsense_says "$(fake_topo_json 4)"   # restore a fast bloxsense for anything after this point

# ---- a bloxsense that TRAPS/IGNORES SIGTERM and sleeps indefinitely must still die (via the outer timeout's
#      SIGKILL grace period reaching the SAME process group, per --foreground), never survive this script, and
#      never block the parent on a pipe it still holds open (checked via a temp file, not a pipe, already)
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20019 1019 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
MARKER1="bloxminerx_test_survivor_bloxsense_$$"
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER1 sleep 30
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20019 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20019
run_hstats_timed
sleep 0.5   # let init reap anything that died, before checking for survivors
survivors1=$(pgrep -f "$MARKER1" || true)
if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && [[ $(jq -r '.khs == "0.00" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]] && [[ -z $survivors1 ]]; then
	ok "SIGTERM-ignoring bloxsense: killed, no survivors, < 3.0 s (${elapsed}s)"
else
	bad "SIGTERM-ignoring bloxsense: killed, no survivors, < 3.0 s" "elapsed=${elapsed}s survivors=[$survivors1] $res"
fi
pkill -9 -f "$MARKER1" 2>/dev/null   # safety net: never leak a process into the box even if this test fails
bloxsense_says "$(fake_topo_json 4)"

# ---- CI finding regression test: the same SIGTERM-ignoring bloxsense (forcing REAL escalation through to
# SIGKILL, not just a TERM that worked) but with a HEALTHY, POSITIVE /2/summary this time - Phase A's own
# fresh total must survive the full escalation path and be returned promptly, never a false 0, even though the
# escalation itself (TERM, grace, KILL) has to run its full course because this bloxsense never responds to
# TERM. This is the exact property a real CI run (GitHub Actions, un-throttled ai02 never reproduced it) once
# measured failing: a 5.01 s poll (hard cap 4.0 s) that returned a false/empty result - traced to a blocking,
# untimed `wait "$CPID"` sitting between the result already being safely written and this file ever reading it
# back (see h-stats.sh's own comment at that exact point for the fix and the full explanation).
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20036 1036 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
MARKER4="bloxminerx_test_survivor_bloxsense2_healthy_$$"
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER4 sleep 30
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_HEALTHY_5" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20036 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
export BLOX_API_PORT=20036
run_hstats_timed
sleep 0.5
survivors4=$(pgrep -f "$MARKER4" || true)
if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && [[ $(jq -r '.khs == "5.00" and (.stats.hs | length) == 1 and .stats.hs[0] == 5' <<< "$res" 2>/dev/null) == true ]] && [[ -z $survivors4 ]]; then
	ok "SIGTERM-ignoring bloxsense + HEALTHY summary: Phase A's fresh positive total survives escalation, < 3.0 s (${elapsed}s)"
else
	bad "SIGTERM-ignoring bloxsense + HEALTHY summary: Phase A's fresh positive total survives escalation, < 3.0 s" "elapsed=${elapsed}s survivors=[$survivors4] $res"
fi
pkill -9 -f "$MARKER4" 2>/dev/null
bloxsense_says "$(fake_topo_json 4)"
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null   # run_hstats_timed never self-cleans like stats_case does

# ---- zombie accumulation: 9a3778a's own fix removed the trailing `wait "$CPID"` outright, reasoning that
# bash's own job control opportunistically reaps a stale zombie as a side effect of the NEXT poll's own
# backgrounding - bounding accumulation to at most one pending zombie across repeated polls in the SAME sourced
# shell (the real Hive agent's own pattern), never unbounded growth. That claim needs a test, not just an
# argument: sources h-stats.sh N times in ONE shell, where EVERY poll is forced through the full TERM-then-KILL
# escalation path (the same SIGTERM-ignoring bloxsense as above), then reads /proc/$$/task/$$/children -
# a BUILTIN-only read (`cat` is the one fork; pgrep/ps would self-match their own invocation's cmdline, which
# contains this test's own marker strings) - to count exactly how many of this shell's own children (zombie or
# otherwise) are still unreaped, and compares /proc/$$/fd's own entry count before and after to catch any
# accompanying fd leak (an unreaped child can also mean an unclosed pipe/fd end still held open).
reset_proc; listen 20037 1037 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
MARKER5="bloxminerx_test_zombie_bloxsense_$$"
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER5 sleep 30
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_HEALTHY_5" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20037 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done

N_ZPOLLS=5
# shellcheck disable=SC2016   # $BLOX_DIR/$$ are meant to expand inside the inner bash -c, not here
zres=$(BLOX_DIR=$BLOX_DIR BLOX_PROCFS_ROOT=$PROC BLOX_API_PORT=20037 bash -c '
	fd_before=$(ls /proc/$$/fd 2>/dev/null | wc -l)
	for i in $(seq 1 '"$N_ZPOLLS"'); do
		. "$BLOX_DIR/h-stats.sh"
	done
	# /proc/<pid>/task/<tid>/children needs CONFIG_CHECKPOINT_RESTORE (not universal - e.g. some container
	# runtimes/kernels do not expose it): explicitly distinguish "unreadable" from "readable and empty" so the
	# outer test can SKIP the child-count half of this assertion rather than silently treating a missing file
	# the same as zero children (which would prove nothing, not pass for a real reason).
	if [[ -r /proc/$$/task/$$/children ]]; then
		children=$(cat /proc/$$/task/$$/children 2>/dev/null)
		children_readable=1
	else
		children=""
		children_readable=0
	fi
	fd_after=$(ls /proc/$$/fd 2>/dev/null | wc -l)
	echo "children_readable=$children_readable children=[$children] fd_before=$fd_before fd_after=$fd_after"
')
children_readable=$(sed -n 's/^children_readable=\([01]\).*/\1/p' <<< "$zres")
nchildren=$(sed -n 's/.*children=\[\(.*\)\] fd_before.*/\1/p' <<< "$zres" | wc -w | tr -d '[:space:]')
fd_before=$(sed -n 's/.*fd_before=\([0-9]*\).*/\1/p' <<< "$zres")
fd_after=$(sed -n 's/.*fd_after=\([0-9]*\).*/\1/p' <<< "$zres")
# fd count: a generous +2 tolerance (never a hard equality) - the ONE bookkeeping `ls`/`wc` pair itself can
# transiently differ by a file descriptor or two depending on exactly when bash's own internal housekeeping
# runs, with no bearing on whether a REAL per-poll fd leak exists (that would grow roughly linearly with
# N_ZPOLLS=5, not stay within a small constant).
fd_ok=0
[[ $fd_before =~ ^[0-9]+$ && $fd_after =~ ^[0-9]+$ ]] && (( fd_after <= fd_before + 2 )) && fd_ok=1
if [[ $children_readable == 0 ]]; then
	if (( fd_ok )); then
		ok "zombie accumulation: /proc/\$\$/task/\$\$/children not readable here (CONFIG_CHECKPOINT_RESTORE off?) - SKIPPED child-count check, fd count still stable (fd $fd_before->$fd_after)"
	else
		bad "zombie accumulation: fd count stable (child-count check skipped - /proc/\$\$/task/\$\$/children not readable here)" "raw=[$zres] fd_before=$fd_before fd_after=$fd_after"
	fi
elif [[ $nchildren =~ ^[0-9]+$ && $nchildren -le 1 ]] && (( fd_ok )); then
	ok "zombie accumulation: <= 1 unreaped child after $N_ZPOLLS forced-escalation polls in one sourced shell, fd count stable (children=$nchildren fd $fd_before->$fd_after)"
else
	bad "zombie accumulation: <= 1 unreaped child after $N_ZPOLLS forced-escalation polls in one sourced shell, fd count stable" "raw=[$zres] children=$nchildren fd_before=$fd_before fd_after=$fd_after"
fi
pkill -9 -f "$MARKER5" 2>/dev/null
bloxsense_says "$(fake_topo_json 4)"

# ---- a `curl` that TRAPS/IGNORES SIGTERM and sleeps indefinitely (simulating a stuck/adversarial API call,
#      invoked directly with no nested timeout of its own) must also be reachable by the same outer kill
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20020 1020 "$BLOX_DIR/xmrig"
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
MARKER2="bloxminerx_test_survivor_curl_$$"
cat > "$FAKEBIN/curl" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER2 sleep 30
EOF
chmod +x "$FAKEBIN/curl"
OLDPATH=$PATH
export PATH="$FAKEBIN:$PATH"
export BLOX_API_PORT=20020
run_hstats_timed
export PATH=$OLDPATH
sleep 0.5
survivors2=$(pgrep -f "$MARKER2" || true)
if awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' && [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]] && [[ -z $survivors2 ]]; then
	ok "SIGTERM-ignoring curl: killed, no survivors, < 3.0 s (${elapsed}s)"
else
	bad "SIGTERM-ignoring curl: killed, no survivors, < 3.0 s" "elapsed=${elapsed}s survivors=[$survivors2] $res"
fi
pkill -9 -f "$MARKER2" 2>/dev/null

# ---- LIB/OUTFILE/HANDSHAKE are now ONE `mktemp -d` allocation, not three separate mktemp calls (a bot-review
# "cheap to cut" startup-cost fix: one fewer fork on the serial "poll-entry -> summary-request-sent" path,
# and - the property this test proves - no more partial-success case to leak a file from: the directory either
# exists, with every path inside it automatically valid, or this call failed outright and nothing under it was
# ever created. A PATH-stub `mktemp` that fails its one-and-only call reproduces that failure.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
FAKEBIN3="$T/fakebin3"; mkdir -p "$FAKEBIN3"
cat > "$FAKEBIN3/mktemp" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$FAKEBIN3/mktemp"
TMPDIR3="$T/tmpdir3"; mkdir -p "$TMPDIR3"
reset_proc; listen 20043 1043 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
jq -n --argjson s "$SUM_HEALTHY_5" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20043 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
OLDPATH=$PATH
res=$(PATH="$FAKEBIN3:$PATH" TMPDIR="$TMPDIR3" BLOX_API_PORT=20043 bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)
export PATH=$OLDPATH
leftover3=$(find "$TMPDIR3" -mindepth 1 2>/dev/null)
if [[ -z $leftover3 ]] && [[ $(jq -r '.khs == "0" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]]; then
	ok "mktemp -d fails -> no leftover temp dir/file, honest fallback"
else
	bad "mktemp -d fails -> no leftover temp dir/file, honest fallback" "leftover=[$leftover3] res=$res"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null

# ---- process-group isolation: the parent must never read/trust the child's pgid before the child itself has
#      confirmed (via a handshake, written only AFTER its own setsid takes effect) that it is truly isolated -
#      otherwise a premature read could see the CALLER's own (inherited) pgid, and a later group-kill could
#      hit the caller itself. Simulated via a test-only env hook that delays the child's handshake write; a
#      "caller" runs in its own session with a marker sibling process that must never be touched no matter what,
#      while a hanging bloxsense still gets cleaned up once the (delayed but eventually valid) handshake arrives.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
CALLER_MARKER="bloxminerx_test_caller_$$"
MARKER3="bloxminerx_test_survivor_bloxsense2_$$"
reset_proc; listen 20026 1026 "$BLOX_DIR/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
cat > "$BLOX_DIR/bloxsense" <<EOF
#!/bin/bash
trap '' TERM
exec -a $MARKER3 sleep 30
EOF
chmod +x "$BLOX_DIR/bloxsense"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20026 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done

cat > "$T/wrapper.sh" <<WRAP
#!/bin/bash
exec -a $CALLER_MARKER sleep 60 > /dev/null 2>&1 &
export BLOX_DIR="$BLOX_DIR"
export BLOX_API_PORT=20026
export BLOX_HSTATS_TEST_HANDSHAKE_DELAY=0.2
t0=\$(date +%s.%N)
. "$BLOX_DIR/h-stats.sh"
t1=\$(date +%s.%N)
jq -nc --arg k "\$khs" --arg s "\$stats" --arg e "\$(awk -v a="\$t0" -v b="\$t1" 'BEGIN{print b-a}')" \
	'{khs: \$k, stats: (\$s | fromjson), elapsed: (\$e | tonumber)}'
WRAP
chmod +x "$T/wrapper.sh"
res=$(setsid bash "$T/wrapper.sh" 2>&1)
sleep 0.5
caller_alive=$(pgrep -f "$CALLER_MARKER" || true)
bloxsense_survivors=$(pgrep -f "$MARKER3" || true)
elapsed=$(jq -r '.elapsed' <<< "$res" 2>/dev/null); [[ -n $elapsed && $elapsed != null ]] || elapsed=99
if [[ -n $caller_alive ]] && [[ -z $bloxsense_survivors ]] && awk -v e="$elapsed" 'BEGIN{exit !(e < 3.0)}' \
	&& [[ $(jq -r '.khs == "0.00" and .stats.hs == [0]' <<< "$res" 2>/dev/null) == true ]]
then
	ok "process-group isolation: caller's group survives, bloxsense reaped, < 3.0 s (${elapsed}s)"
else
	bad "process-group isolation: caller's group survives, bloxsense reaped, < 3.0 s" \
		"caller_alive=[$caller_alive] bloxsense_survivors=[$bloxsense_survivors] elapsed=$elapsed res=$res"
fi
pkill -9 -f "$CALLER_MARKER" 2>/dev/null
pkill -9 -f "$MARKER3" 2>/dev/null
bloxsense_says "$(fake_topo_json 4)"

# ================================================================== diagnostics: one log line per state change
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
PKG2="$T/pkg2"; mkdir -p "$PKG2" "$T/log2"
cp "$BLOX_DIR/h-config.sh" "$BLOX_DIR/h-stats.sh" "$PKG2/"
ln -sf "$BLOX_DIR/xmrig" "$PKG2/xmrig"
ln -sf "$BLOX_DIR/bloxsense" "$PKG2/bloxsense"   # bloxsense_says() below keeps controlling both via this symlink
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config2.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log2/bloxminer-x#" "$BLOX_DIR/h-manifest.conf" > "$PKG2/h-manifest.conf"
jq -n '{pools: [{algo: "rx/0"}]}' > "$T/config2.json"
STATE2="$T/state2"; LOG2="$T/log2/bloxminer-x.stats.log"; MAINLOG2="$T/log2/bloxminer-x.log"
run_pkg2() { mkdir -p "$STATE2" "$T/log2"; BLOX_DIR=$PKG2 BLOX_STATE_DIR=$STATE2 BLOX_API_PORT=$1 BLOX_PROCFS_ROOT=$PROC \
	bash -c '. "$BLOX_DIR/h-stats.sh"' > /dev/null 2>&1; }
loglines() { grep -c "$1" "$LOG2" 2>/dev/null || true; }

rm -rf "$STATE2" "$T/log2"; reset_proc   # nothing listening: unavailable
run_pkg2 20020
if [[ $(loglines "stats API unavailable") == 1 ]]; then ok "state log: first unavailable is logged once"; else bad "state log: first unavailable is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi
run_pkg2 20020   # still down: no duplicate line
if [[ $(loglines "stats API unavailable") == 1 ]]; then ok "state log: repeated unavailable is not re-logged"; else bad "state log: repeated unavailable is not re-logged" "$(cat "$LOG2" 2>/dev/null)"; fi

reset_proc; listen 20021 1021 "$PKG2/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
# BACK_SOME_REAL (complete, no nulls), not BACK_NULLS: a P2 fix (bot review) now defers note_state ok/
# unverified until Phase B's result is actually ACCEPTED - BACK_NULLS is deliberately INCOMPLETE (that is the
# whole point of the dedicated "healthy summary + backends with a null thread rate" case elsewhere in this
# file), so it would be correctly REJECTED here too (state -> shallow, not ok), never reaching "recovered" at
# all. This section is testing accepted-path LOGGING specifically, so it needs a fixture Phase B actually
# accepts; ports 20022/20023 below reuse this SAME $T/replies.json (they write no fixture of their own).
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20021 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20021   # recovered: verified per-core rows again
if [[ $(loglines "recovered") == 1 && $(loglines "stats API unavailable") == 1 ]]; then ok "state log: recovery from unavailable is logged once"; else bad "state log: recovery from unavailable is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20022 1022 "$PKG2/xmrig"   # no tasks set up: affinity present but never independently confirmed
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20022 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20022
if [[ $(loglines "affinity not verified") == 1 ]]; then ok "state log: unverified transition is logged once"; else bad "state log: unverified transition is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi
run_pkg2 20022   # still unverified: no duplicate
if [[ $(loglines "affinity not verified") == 1 ]]; then ok "state log: repeated unverified is not re-logged"; else bad "state log: repeated unverified is not re-logged" "$(cat "$LOG2" 2>/dev/null)"; fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20023 1023 "$PKG2/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20023 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20023   # recovered again, from unverified this time
if [[ $(loglines "recovered") == 2 ]]; then ok "state log: recovery from unverified is logged once"; else bad "state log: recovery from unverified is logged once" "$(cat "$LOG2" 2>/dev/null)"; fi

if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} bloxminer-x: ' "$LOG2" 2>/dev/null; then
	ok "state log: each line is timestamped"
else
	bad "state log: each line is timestamped" "$(cat "$LOG2" 2>/dev/null)"
fi

# ---- P2 (bot review): note_state used to be called for Phase B's OWN attempted path (ok/unverified) before
# completeness/consistency were even checked - a REJECTED Phase B result still logged "recovered"/showed the
# wrong state, even though Phase A's own total was what actually shipped. Each of the three distinct rejection
# reasons (incomplete rows, >10% mismatch with Phase A, and a failed final composition) must leave the state
# as "shallow" (the SAME state Phase A's own early exits already use for "total only, no per-core breakdown"),
# and the transition log line must appear only on a REAL transition - not on every poll that happens to land
# on "shallow" for a DIFFERENT underlying reason than the previous one.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
rm -rf "$STATE2" "$T/log2"; mkdir -p "$T/log2"

reset_proc; listen 20039 1039 "$PKG2/xmrig"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_NULLS" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20039 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20039   # incomplete (null thread rate) -> rejected -> shallow, logged (first-ever transition)
if [[ $(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) == shallow && $(loglines "showing total only this poll") == 1 ]]; then
	ok "state log: incomplete Phase B -> state is shallow, logged once"
else
	bad "state log: incomplete Phase B -> state is shallow, logged once" "state=$(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) $(cat "$LOG2" 2>/dev/null)"
fi
run_pkg2 20039   # same incomplete condition again -> still shallow -> NOT re-logged
if [[ $(loglines "showing total only this poll") == 1 ]]; then ok "state log: repeated incomplete Phase B is not re-logged"; else bad "state log: repeated incomplete Phase B is not re-logged" "$(cat "$LOG2" 2>/dev/null)"; fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20040 1040 "$PKG2/xmrig"
jq -n --argjson s "$SUM_HEALTHY_50" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20040 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20040   # complete but >10% mismatch with Phase A -> rejected -> still shallow, same state as before
	# -> NOT re-logged (shallow -> shallow is not a transition, even though the REASON differs)
if [[ $(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) == shallow && $(loglines "showing total only this poll") == 1 ]]; then
	ok "state log: >10% Phase A/B mismatch -> state is shallow, no new log line (same state as before)"
else
	bad "state log: >10% Phase A/B mismatch -> state is shallow, no new log line" "state=$(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) $(cat "$LOG2" 2>/dev/null)"
fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20041 1041 "$PKG2/xmrig"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20041 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
BLOX_DIR=$PKG2 BLOX_STATE_DIR=$STATE2 BLOX_API_PORT=20041 BLOX_PROCFS_ROOT=$PROC BLOX_HSTATS_TEST_FORCE_STATS_FAIL=1 \
	bash -c '. "$BLOX_DIR/h-stats.sh"' > /dev/null 2>&1   # SUM_OK (khs_fresh=0) is auto-consistent, so this
		# reaches the composition step at all before being force-failed there - see the dedicated composition-
		# failure test above for why a healthy-but-different Phase A total would never reach it in the first place
if [[ $(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) == shallow && $(loglines "showing total only this poll") == 1 ]]; then
	ok "state log: failed stats composition -> state is shallow, no new log line (same state as before)"
else
	bad "state log: failed stats composition -> state is shallow, no new log line" "state=$(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) $(cat "$LOG2" 2>/dev/null)"
fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc; listen 20042 1042 "$PKG2/xmrig"; for c in $(seq 0 3); do task "t$c" "$c"; done
bloxsense_says "$(fake_topo_json 4)"
jq -n --argjson s "$SUM_OK" --argjson b "$BACK_SOME_REAL" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"; python3 "$HERE/fake_xmrig_api.py" 20042 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
run_pkg2 20042   # complete, consistent (Phase A==0, auto), composition succeeds, percore verified -> ACCEPTED
	# -> state becomes ok, logged exactly once (the first "recovered" transition anywhere in this fresh section)
if [[ $(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) == ok && $(loglines "recovered") == 1 ]]; then
	ok "state log: accepted Phase B (percore) -> state is ok, recovery logged exactly once"
else
	bad "state log: accepted Phase B (percore) -> state is ok, recovery logged exactly once" "state=$(cat "$STATE2/.bloxminer-x-hstats-state" 2>/dev/null) $(cat "$LOG2" 2>/dev/null)"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
bloxsense_says "$(fake_topo_json 4)"

# ---- XMRig's own log file is written at XMRig's own tracked offset with no O_APPEND (FileLogWriter), so
#      anything else appended there is silently overwritten by XMRig's next write - confirmed on a live rig
#      (state transitions really happened, per the state file, but no diagnostic line ever survived in
#      XMRig's log). Simulate a concurrent XMRig-like writer that keeps rewriting the main log at a fixed
#      offset while a transition happens, and confirm the diagnostic still survives - in its own file.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
rm -rf "$STATE2" "$T/log2"; mkdir -p "$T/log2"
printf 'XMRIG STARTUP BANNER\n' > "$MAINLOG2"
(
	i=0
	while [[ $i -lt 20 ]]; do
		printf 'XMRIG LOG LINE %03d (fixed-offset rewrite, no append)\n' "$i" > "$MAINLOG2" 2>/dev/null
		i=$((i + 1))
		sleep 0.05
	done
) &
XMRIG_WRITER_PID=$!
reset_proc   # nothing listening: unavailable
run_pkg2 20030
kill "$XMRIG_WRITER_PID" 2>/dev/null; wait "$XMRIG_WRITER_PID" 2>/dev/null
if grep -q "bloxminer-x: stats API unavailable" "$LOG2" 2>/dev/null; then
	ok "diagnostics survive a concurrent fixed-offset rewriter of the main log"
else
	bad "diagnostics survive a concurrent fixed-offset rewriter of the main log" \
		"statslog=$(cat "$LOG2" 2>/dev/null) mainlog=$(cat "$MAINLOG2" 2>/dev/null)"
fi
if ! grep -q "bloxminer-x:" "$MAINLOG2" 2>/dev/null; then
	ok "the main (XMRig) log never receives a bloxminer-x diagnostic line"
else
	bad "the main (XMRig) log never receives a bloxminer-x diagnostic line" "$(cat "$MAINLOG2" 2>/dev/null)"
fi

kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
reset_proc   # a transition-worthy run (unavailable), captured without discarding stdout this time
stdout_out=$(BLOX_DIR=$PKG2 BLOX_STATE_DIR=$STATE2 BLOX_API_PORT=20024 BLOX_PROCFS_ROOT=$PROC bash -c '. "$BLOX_DIR/h-stats.sh"' 2>/dev/null)
if [[ -z $stdout_out ]]; then ok "state log: nothing is ever printed to stdout"; else bad "state log: nothing is ever printed to stdout" "stdout=$stdout_out"; fi

# ================================================================== SECURITY: arithmetic-context injection
# Every value this file ever reads from the XMRig HTTP API (jq), bloxsense, or $ENRICHFILE must pass a strict
# regex/type check BEFORE it can reach a bash arithmetic context ((( )), $(( )), [[ -le/-lt/-gt ]], etc): that
# context recursively re-evaluates an operand that still looks like an expression, so an unvalidated value there
# is root-level command injection (this collector runs as root on a real Hive rig). A fake API, a fake bloxsense,
# and a hand-crafted $ENRICHFILE each supply a payload shaped like `a[$(touch <marker>)]` in every numeric field
# this file reads; none may ever create the marker file, and the poll must still return a safe, defined result.
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
MARK_INJ="$T/injmark"; rm -f "${MARK_INJ}".*
# shellcheck disable=SC2016   # deliberately literal: this is the attack PAYLOAD text itself (must reach h-stats.sh
# as the literal characters `a[$(touch ...)]`, never pre-expanded by THIS shell) - the whole point of the test.
INJ='a[$(touch '"$MARK_INJ"'.api)]'
SUM_INJ=$(jq -n --arg u "$INJ" '{uptime: $u, connection: {accepted: $u, rejected: $u}, algo: "rx/0", version: "6.26.0", hashrate: {total: [$u]}}')
BACK_INJ=$(jq -n --arg u "$INJ" '[{type: "cpu", threads: [{affinity: 0, hashrate: [$u, null, null]}]}]')

reset_proc; listen 20040 2040 "$BLOX_DIR/xmrig"
task "t0" "0"
# /proc/<pid>/stat: field 22 (starttime) is the 20th whitespace-separated token after the ")" (see
# _rx_pid_start()'s own header) - a fixed, valid fake value, matched by $ENRICHFILE's "start=" line below so the
# enrichment branch is actually entered (an empty/mismatched pidstart would skip it entirely, proving nothing).
printf '%s (xmrig) S 1 2040 2040 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 1234567890\n' "$FAKE_PID" > "$PROC/$FAKE_PID/stat"
# shellcheck disable=SC2016   # same as above: a literal payload string, not an expression meant to expand here.
INJ_TEMP='a[$(touch '"$MARK_INJ"'.sense)]'
bloxsense_says "$(jq -n --arg t "$INJ_TEMP" '{cpus: [{cpu: 0, pkg: 0, core: 0, temp: 55, src: "core"}], pkg_temp: $t, power_w: $t, ccd_reason: "inj"}')"
# shellcheck disable=SC2016   # %s is the printf conversion, not a shell expansion - the `$(touch ...)]` text
# inside the format string is the literal payload $ENRICHFILE's ts=/temp= lines must carry, verbatim.
printf 'ts=a[$(touch %s.enrich)]\npid=%s\nstart=1234567890\ntemp=a[$(touch %s.enrichtemp)]\n' \
	"$MARK_INJ" "$FAKE_PID" "$MARK_INJ" > "$BLOX_DIR/.bloxminer-x-hstats-enrich"

jq -n --argjson s "$SUM_INJ" --argjson b "$BACK_INJ" '{summary: $s, backends: $b}' > "$T/replies.json"
: > "$T/api.out"
python3 "$HERE/fake_xmrig_api.py" 20040 "$T/replies.json" > "$T/api.out" 2>&1 & API_PID=$!
for _ in $(seq 50); do grep -q ready "$T/api.out" && break; sleep 0.1; done
grep -q ready "$T/api.out" || bad "injection: fake API did not start" "$(cat "$T/api.out")"

res=$(BLOX_STATE_DIR=$BLOX_DIR BLOX_API_PORT=20040 BLOX_PROCFS_ROOT=$PROC bash -c '. "$BLOX_DIR/h-stats.sh"; jq -nc --arg k "$khs" --arg s "$stats" "{khs: \$k, stats: (\$s | if . == \"\" then null else fromjson end)}"' 2>&1)

if ! ls "${MARK_INJ}".* > /dev/null 2>&1; then
	ok "injection: API/bloxsense/ENRICHFILE payloads never execute (no marker file)"
else
	bad "injection: API/bloxsense/ENRICHFILE payloads never execute (no marker file)" "created: $(ls "${MARK_INJ}".* 2>/dev/null)"
fi
if [[ $(jq -r '.khs' <<< "$res" 2>/dev/null) =~ ^[0-9]+\.[0-9]{2}$ ]]; then
	ok "injection: poll still returns a safe, defined result (malicious fields forced to 0/null, never passed through)"
else
	bad "injection: poll still returns a safe, defined result (malicious fields forced to 0/null, never passed through)" "$res"
fi
kill "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null
rm -f "$BLOX_DIR/.bloxminer-x-hstats-enrich"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
