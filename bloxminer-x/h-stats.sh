#!/usr/bin/env bash
# Sourced by the Hive agent: must set $khs (total kH/s) and $stats (JSON). One 3.0 s budget total: both API
# calls are curl --max-time 0.5 against localhost, bloxsense runs under `timeout 1.8`, everything else is jq.
# Before trusting 127.0.0.1:$API_PORT at all, this checks that the listening socket belongs to OUR xmrig
# (its pid's /proc/<pid>/exe is this package's ./xmrig) - a foreign miner bound to the same port is never read.
# Rows: one per physical core (SMT threads summed from /2/backends' per-thread affinity + hashrate[0], 10 s
# window) when every thread reports a real affinity to a CPU bloxsense's topology also knows, AND the xmrig
# process's own task list (/proc/<pid>/task/*/status) shows that exact multiset of single-CPU-pinned tasks -
# i.e. the binding is independently confirmed, not just asserted by the API. Otherwise one row per thread with
# the package temperature (the core mapping is "unbound"). A row's rate is XMRig's own 10 s average; it drops
# to 0 within ~10-20 s of hashing stopping - this is not a "completed work" stamp. khs is always the sum of rows.
# shellcheck disable=SC2034   # khs and stats are read by the Hive agent that sources this file
. "${BLOX_DIR:-/hive/miners/custom/bloxminer-x}/h-manifest.conf"   # BLOX_DIR: tests only

PROC=${BLOX_PROCFS_ROOT:-/proc}          # /proc path prefix; tests only
PKG=${BLOX_DIR:-/hive/miners/custom/bloxminer-x}
PORT=${BLOX_API_PORT:-${API_PORT:-4069}}
VER="$CUSTOM_VERSION (xmrig 6.26.0)"
algo=$(jq -r '.pools[0].algo // empty' "$CUSTOM_CONFIG_FILENAME" 2>/dev/null); [[ -n $algo ]] || algo="rx/0"

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

fallback() {   # $1 = a single row's temperature (bloxsense pkg_temp, JSON number or null), default null
	khs=0
	stats=$(jq -nc --arg ver "$VER" --arg algo "$algo" --argjson temp "${1:-null}" \
		'{hs: [0], hs_units: "khs", temp: [$temp], ar: [0, 0], uptime: 0, ver: $ver, algo: $algo}')
}

# ---------------------------------------------------------------- API ownership: /proc/net/tcp -> inode -> pid -> exe
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
if (( ! owned )); then fallback ""; return 0 2>/dev/null || exit 0; fi

# ---------------------------------------------------------------- the two API calls, 0.5 s each
sum=$(curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/2/summary" 2>/dev/null)
back=$(curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/2/backends" 2>/dev/null)
if ! jq -e . > /dev/null 2>&1 <<< "$sum" || ! jq -e . > /dev/null 2>&1 <<< "$back"; then
	fallback ""; return 0 2>/dev/null || exit 0
fi

uptime=$(jq -r '.uptime // 0' <<< "$sum"); int "$uptime" || uptime=0
acc=$(jq -r '.connection.accepted // 0' <<< "$sum"); int "$acc" || acc=0
rej=$(jq -r '.connection.rejected // 0' <<< "$sum"); int "$rej" || rej=0

threads=$(jq -c '[.[] | select(.type == "cpu") | .threads[]?] // []' <<< "$back" 2>/dev/null)
[[ -n $threads ]] || threads='[]'
naff=$(jq 'length' <<< "$threads" 2>/dev/null); int "$naff" || naff=0
if (( naff == 0 )); then fallback ""; return 0 2>/dev/null || exit 0; fi

# ---------------------------------------------------------------- sensors (own budget: timeout 1.8, internal 1.0 s sample)
sense=$(timeout 1.8 "$PKG/bloxsense" --json 2>/dev/null)
jq -e . > /dev/null 2>&1 <<< "$sense" || sense='{"cpus":[],"pkg_temp":null,"power_w":null,"ccd_reason":""}'
pkg_temp=$(jq -c '.pkg_temp' <<< "$sense")
power=$(jq -r '.power_w // empty' <<< "$sense")

# ---------------------------------------------------------------- binding verification (every thread bound + confirmed)
percore=0
if jq -e --argjson s "$sense" 'all(.affinity >= 0) and (map(.affinity as $a | ($s.cpus | any(.cpu == $a))) | all)' \
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
	rows=$(jq -c --argjson s "$sense" '
		($s.cpus | map({key: (.cpu | tostring), value: {pkg: .pkg, core: .core, temp: .temp}}) | from_entries) as $topo
		| map(. + {pc: $topo[(.affinity | tostring)]})
		| group_by([.pc.pkg, .pc.core])
		| map({khs: ((map((.hashrate[0] // 0) / 1000) | add) * 100 | round / 100), temp: .[0].pc.temp})' <<< "$threads")
else
	rows=$(jq -c --argjson pt "$pkg_temp" 'map({khs: (((.hashrate[0] // 0) / 1000) * 100 | round / 100), temp: $pt})' \
		<<< "$threads")
fi

khs=$(jq -r '[.[].khs] | add // 0' <<< "$rows" | awk '{printf "%.2f", $1}')
stats=$(jq -nc --argjson hs "$(jq -c '[.[].khs]' <<< "$rows")" --argjson temp "$(jq -c '[.[].temp]' <<< "$rows")" \
	--argjson ar "$(jq -nc --argjson a "$acc" --argjson r "$rej" '[$a, $r]')" --argjson uptime "$uptime" \
	--arg ver "$VER" --arg algo "$algo" --arg power "$power" \
	'{hs: $hs, hs_units: "khs", temp: $temp, ar: $ar, uptime: $uptime, ver: $ver, algo: $algo}
	 + (if ($power | test("^[0-9]+(\\.[0-9]+)?$")) then {cpu_power: ($power | tonumber)} else {} end)')
