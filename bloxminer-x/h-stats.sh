#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON). ONE shared 3.0 s deadline for the
# whole run: the remaining time is recomputed before every step (both curls, the /proc scan, bloxsense) and
# whichever steps still fit get whatever is left; once the budget is spent, remaining optional steps are
# skipped and the script falls back rather than risk running past its budget.
# Before trusting 127.0.0.1:$API_PORT at all, this checks that the listening socket belongs to OUR xmrig
# (its pid's /proc/<pid>/exe is this package's ./xmrig) - a foreign miner bound to the same port is never read.
# Both API replies are schema-checked before use (object/array shape, numeric affinity, array hashrate) -
# a reply that merely looks like JSON but not like XMRig's own shape is treated the same as no reply. Even a
# schema-valid rate is clamped to 0 if it is not a finite, non-negative number: hs is never negative.
# Rows: one per physical core (SMT threads summed from /2/backends' per-thread affinity + hashrate[0], 10 s
# window) when every thread reports a real affinity to a CPU bloxsense's topology also knows, AND the xmrig
# process's own task list (/proc/<pid>/task/*/status) shows that exact multiset of single-CPU-pinned tasks -
# i.e. the binding is independently confirmed, not just asserted by the API. Otherwise one row per thread with
# the package temperature (the core mapping is "unbound"). A row's rate is XMRig's own 10 s average; it drops
# to 0 within ~10-20 s of hashing stopping - this is not a "completed work" stamp. khs is always the sum of rows.
# State changes (API unavailable / affinity not verified / recovered) get one line in the miner log, never on
# stdout (this file is sourced by Hive's agent, not run as a standalone script).
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
. "${BLOX_DIR:-/hive/miners/custom/bloxminer-x}/h-manifest.conf"   # BLOX_DIR: tests only

PROC=${BLOX_PROCFS_ROOT:-/proc}          # /proc path prefix; tests only
PKG=${BLOX_DIR:-/hive/miners/custom/bloxminer-x}
PORT=${BLOX_API_PORT:-${API_PORT:-4069}}
VER="bloxminer-x $CUSTOM_VERSION (xmrig 6.26.0)"
algo=$(jq -r '.pools[0].algo // empty' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null); [[ -n $algo ]] || algo="rx/0"

BUDGET=3.0
t0=$(date +%s.%N)
now() { date +%s.%N; }
remaining() { awk -v s="$t0" -v n="$(now)" -v b="$BUDGET" 'BEGIN{r=b-(n-s); if (r<0) r=0; printf "%.2f", r}'; }
have_budget() { awk -v r="$1" 'BEGIN{exit !(r > 0.05)}'; }   # < 50 ms left is not worth attempting

int() { [[ $1 =~ ^[0-9]+$ ]]; }

# a Cpus_allowed_list value ("0-3,8" or "5"): prints the single CPU number when it expands to exactly one, else nothing
single_cpu() {
	local list=$1 count=0 last='' p a b
	IFS=',' read -ra parts <<< "$list"
	for p in "${parts[@]}"; do
		if [[ $p == *-* ]]; then
			a=${p%-*}; b=${p#*-}
			int "$a" && int "$b" || return 0
			count=$(( count + b - a + 1 )); last=$a
		else
			int "$p" || return 0
			count=$(( count + 1 )); last=$p
		fi
		(( count > 1 )) && return 0
	done
	(( count == 1 )) && echo "$last"
}

# ---------------------------------------------------------------- diagnostics: one log line per state change
STATEDIR=${BLOX_STATE_DIR:-}
if [[ -z $STATEDIR ]]; then [[ -d /run/hive ]] && STATEDIR=/run/hive || STATEDIR=$PKG; fi
STATEFILE="$STATEDIR/.bloxminer-x-hstats-state"
note_state() {   # $1 = ok | unverified | unavailable; logs only on a transition, never to stdout
	local prev="" cur=$1 msg=""
	[[ -f $STATEFILE ]] && prev=$(<"$STATEFILE")
	[[ $prev == "$cur" ]] && return 0
	case $cur in
		unavailable) msg="bloxminer-x: stats API unavailable" ;;
		unverified)  msg="bloxminer-x: affinity not verified, showing per-thread rows" ;;
		ok)          [[ -n $prev ]] && msg="bloxminer-x: recovered" ;;
	esac
	[[ -n $msg ]] && { printf '%s\n' "$msg" >> "$CUSTOM_LOG_BASENAME.log"; } 2>/dev/null
	{ printf '%s' "$cur" > "$STATEFILE"; } 2>/dev/null
}

fallback() {   # $1 = a single row's temperature (bloxsense pkg_temp, JSON number or null), default null
	khs=0
	stats=$(jq -nc --arg ver "$VER" --arg algo "$algo" --argjson temp "${1:-null}" \
		'{hs: [0], hs_units: "khs", temp: [$temp], ar: [0, 0], uptime: 0, ver: $ver, algo: $algo}')
}

# schema validators: a reply that parses as JSON but does not look like XMRig's own shape is not used
valid_summary() { jq -e 'type == "object" and (.version | type == "string")' > /dev/null 2>&1 <<< "$1"; }
valid_backends() {
	jq -e '
		type == "array" and
		(map(select(.type == "cpu")) as $c | ($c | length) <= 1 and
		 ($c | all(.threads == null or (
		   (.threads | type) == "array" and
		   (.threads | all(type == "object" and (.affinity | type == "number") and (.hashrate | type == "array")))
		 ))))
	' > /dev/null 2>&1 <<< "$1"
}

# ---------------------------------------------------------------- API ownership: /proc/net/tcp -> inode -> pid -> exe
r=$(remaining)
if ! have_budget "$r"; then note_state unavailable; fallback ""; return 0 2>/dev/null || exit 0; fi
port_hex=$(printf '%04X' "$PORT")
inode=$(awk -v p="$port_hex" 'NR > 1 { split($2, a, ":"); if (a[1] == "0100007F" && a[2] == p && $4 == "0A") print $10 }' \
	"$PROC/net/tcp" 2>/dev/null | head -n1)
owner_pid=""
if [[ -n $inode ]]; then
	for fd in "$PROC"/[0-9]*/fd/*; do
		[[ -e $fd || -L $fd ]] || continue
		[[ $(readlink "$fd" 2>/dev/null) == "socket:[$inode]" ]] || continue
		owner_pid=${fd#"$PROC"/}; owner_pid=${owner_pid%%/*}
		break
	done
fi
owned=0
if [[ -n $owner_pid ]] && [[ $(readlink "$PROC/$owner_pid/exe" 2>/dev/null) == "$PKG/xmrig" ]]; then owned=1; fi
if (( ! owned )); then note_state unavailable; fallback ""; return 0 2>/dev/null || exit 0; fi

# ---------------------------------------------------------------- the two API calls, sharing what's left of the budget
r=$(remaining)
if ! have_budget "$r"; then note_state unavailable; fallback ""; return 0 2>/dev/null || exit 0; fi
sum=$(curl -fsS --max-time "$r" "http://127.0.0.1:$PORT/2/summary" 2>/dev/null)

r=$(remaining)
if ! have_budget "$r"; then note_state unavailable; fallback ""; return 0 2>/dev/null || exit 0; fi
back=$(curl -fsS --max-time "$r" "http://127.0.0.1:$PORT/2/backends" 2>/dev/null)

if ! jq -e . > /dev/null 2>&1 <<< "$sum" || ! valid_summary "$sum" || ! jq -e . > /dev/null 2>&1 <<< "$back" || ! valid_backends "$back"; then
	note_state unavailable; fallback ""; return 0 2>/dev/null || exit 0
fi

uptime=$(jq -r '.uptime // 0' <<< "$sum"); int "$uptime" || uptime=0
acc=$(jq -r '.connection.accepted // 0' <<< "$sum"); int "$acc" || acc=0
rej=$(jq -r '.connection.rejected // 0' <<< "$sum"); int "$rej" || rej=0

threads=$(jq -c '[.[] | select(.type == "cpu") | .threads[]?] // []' <<< "$back" 2>/dev/null)
[[ -n $threads ]] || threads='[]'
naff=$(jq 'length' <<< "$threads" 2>/dev/null); int "$naff" || naff=0
if (( naff == 0 )); then fallback ""; return 0 2>/dev/null || exit 0; fi

# ---------------------------------------------------------------- sensors: whatever is left of the shared budget
r=$(remaining)
if have_budget "$r"; then
	sense=$(timeout "$r" "$PKG/bloxsense" --json 2>/dev/null)
else
	sense=""
fi
jq -e . > /dev/null 2>&1 <<< "$sense" || sense='{"cpus":[],"pkg_temp":null,"power_w":null,"ccd_reason":""}'
pkg_temp=$(jq -c '.pkg_temp' <<< "$sense")
power_raw=$(jq -c '.power_w' <<< "$sense")

# ---------------------------------------------------------------- binding verification, budget permitting
percore=0
r=$(remaining)
if have_budget "$r" && jq -e --argjson s "$sense" 'all(.affinity >= 0) and (map(.affinity as $a | ($s.cpus | any(.cpu == $a))) | all)' \
	<<< "$threads" > /dev/null 2>&1
then
	singles=()
	if [[ -d $PROC/$owner_pid/task ]]; then
		for st in "$PROC/$owner_pid"/task/*/status; do
			[[ -f $st ]] || continue
			list=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' "$st" | tr -d '[:space:]')
			[[ -n $list ]] || continue
			c=$(single_cpu "$list")
			[[ -n $c ]] && singles+=("$c")
		done
	fi
	task_set=$(printf '%s\n' "${singles[@]}" | jq -R 'select(length > 0) | tonumber' | jq -s 'sort')
	api_set=$(jq -c '[.[].affinity] | sort' <<< "$threads")
	jq -e -n --argjson t "$task_set" --argjson a "$api_set" '$t == $a' > /dev/null 2>&1 && percore=1
fi

if (( percore )); then
	note_state ok
	rows=$(jq -c --argjson s "$sense" '
		def rate0: (.hashrate[0]) as $r | if ($r == null or ($r | type) != "number" or ($r | isnan) or ($r | isinfinite) or $r < 0) then 0 else $r end;
		($s.cpus | map({key: (.cpu | tostring), value: {pkg: .pkg, core: .core, temp: .temp}}) | from_entries) as $topo
		| map(. + {pc: $topo[(.affinity | tostring)], r0: rate0})
		| group_by([.pc.pkg, .pc.core])
		| map({khs: ((map(.r0 / 1000) | add) * 100 | round / 100), temp: .[0].pc.temp})' <<< "$threads")
else
	note_state unverified
	rows=$(jq -c --argjson pt "$pkg_temp" '
		def rate0: (.hashrate[0]) as $r | if ($r == null or ($r | type) != "number" or ($r | isnan) or ($r | isinfinite) or $r < 0) then 0 else $r end;
		map({khs: ((rate0 / 1000) * 100 | round / 100), temp: $pt})' <<< "$threads")
fi

khs=$(jq -r '[.[].khs] | add // 0' <<< "$rows" | awk '{printf "%.2f", $1}')
stats=$(jq -nc --argjson hs "$(jq -c '[.[].khs]' <<< "$rows")" --argjson temp "$(jq -c '[.[].temp]' <<< "$rows")" \
	--argjson ar "$(jq -nc --argjson a "$acc" --argjson r "$rej" '[$a, $r]')" --argjson uptime "$uptime" \
	--arg ver "$VER" --arg algo "$algo" --argjson power "$power_raw" \
	'{hs: $hs, hs_units: "khs", temp: $temp, ar: $ar, uptime: $uptime, ver: $ver, algo: $algo}
	 + (if ($power | type) == "number" and $power > 0 then {cpu_power: $power} else {} end)')
