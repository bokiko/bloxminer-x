#!/usr/bin/env bash
# Build the BloxMiner-X config.json from the flight sheet. jq builds all JSON, so every value is escaped -
# nothing from the flight sheet or Extra config is ever interpolated into a shell command.
#   CUSTOM_URL         pool: stratum+tcp://host:port, stratum+ssl://host:port or host:port (first line is used)
#   CUSTOM_TEMPLATE    wallet(.worker) template, e.g. %WAL%.%WORKER_NAME% -> pools[0].user
#   CUSTOM_PASS        pool password (NOT a thread count - this differs from the Verus BloxMiner) -> pools[0].pass
#   CUSTOM_ALGO        RandomX variant: rx/0, rx/wow, rx/arq, rx/graft, rx/sfx or rx/yada; empty = rx/0
#   CUSTOM_USER_CONFIG optional JSON members, merged into the top-level config, e.g. "print-time": 30
#                      "tls": true            - force TLS on the pool connection (stratum+ssl:// already does)
#                      "1gb-pages": true      - opt-in only; needs >= 3 GiB free per NUMA node (checked below),
#                                               dropped with a message otherwise
#                      "cpu": {...}           - merged into the cpu object (huge-pages/enabled stay fixed)
# Threads are XMRig's own cache-aware autoconfig; Extra config can steer them via "cpu": {"max-threads-hint": N}
# or "cpu": {"rx": [...]} (XMRig's own keys, passed through as-is).
. "${BLOX_DIR:-/hive/miners/custom/bloxminer-x}/h-manifest.conf"   # BLOX_DIR: tests only
SYSROOT=${BLOX_SYSFS_ROOT:-}                                       # /sys path prefix; tests only

# top-level Extra config keys BloxMiner-X always sets itself (0% fee, local read-only API, our own log file);
# "cpu.enabled" is protected the same way but lives one level down and is handled separately below.
PROTECTED='["donate-level","donate-over-proxy","http","api","autosave","log-file","background","syslog","opencl","cuda"]'
ALGOS='["rx/0","rx/wow","rx/arq","rx/graft","rx/sfx","rx/yada"]'

fail() { echo "$1"; message error "$1" 2>/dev/null; exit 1; }

url=$(head -n1 <<< "$CUSTOM_URL" | tr -d '[:space:]')
[[ -n $url ]] || fail "BloxMiner-X: the pool URL in the flight sheet is empty"
[[ $url == stratum+* ]] || url="stratum+tcp://$url"   # XMRig parses stratum+tcp:// / stratum+ssl:// itself

algo=${CUSTOM_ALGO:-rx/0}
if ! jq -ne --argjson a "$ALGOS" --arg algo "$algo" '$a | index($algo) != null' > /dev/null; then
	fail "BloxMiner-X: Algorithm must be one of $(jq -rc . <<< "$ALGOS") (got $algo)"
fi

extra='{}'
if [[ -n $CUSTOM_USER_CONFIG ]]; then
	extra=$(jq -ce 'if type == "object" then . else error end' <<< "{$CUSTOM_USER_CONFIG}" 2>/dev/null) ||
		fail "BloxMiner-X: Extra config must be JSON members, e.g. \"print-time\": 30"
fi

# "tls": boolean only, forces TLS on the pool connection (stratum+ssl:// already sets it without this)
tls_json=null
if jq -e 'has("tls")' <<< "$extra" > /dev/null; then
	t=$(jq -r '.tls | if type == "boolean" then tostring else "(\(type))" end' <<< "$extra")
	[[ $t == true || $t == false ]] || fail "BloxMiner-X: Extra config \"tls\" must be true or false (got $t)"
	tls_json=$t
fi

# "1gb-pages": opt-in only, and only when every NUMA node reports >= 3 GiB free right now (XMRig reserves the
# pages itself at startup via sysfs; a failed reservation silently falls back to 2 MB pages).
onegb=false
if jq -e 'has("1gb-pages")' <<< "$extra" > /dev/null; then
	v=$(jq -r '."1gb-pages" | if type == "boolean" then tostring else "(\(type))" end' <<< "$extra")
	[[ $v == true || $v == false ]] || fail "BloxMiner-X: Extra config \"1gb-pages\" must be true or false (got $v)"
	if [[ $v == true ]]; then
		nodes=("$SYSROOT"/sys/devices/system/node/node[0-9]*/meminfo)
		if [[ ! -e ${nodes[0]} ]]; then
			echo "BloxMiner-X: Extra config \"1gb-pages\" ignored: no NUMA memory information to verify 3 GiB/node"
		else
			short=""
			for f in "${nodes[@]}"; do
				kb=$(sed -n 's/.*MemFree:[[:space:]]*\([0-9]\+\) kB/\1/p' "$f")
				[[ $kb =~ ^[0-9]+$ ]] && (( kb >= 3 * 1024 * 1024 )) || short+="${short:+, }$(basename "$(dirname "$f")")"
			done
			if [[ -n $short ]]; then
				echo "BloxMiner-X: Extra config \"1gb-pages\" ignored: < 3 GiB free on $short"
			else
				onegb=true
			fi
		fi
	fi
fi

# cpu.enabled is protected (BloxMiner-X always enables the CPU backend); everything else under "cpu" passes through
xcpu=$(jq -c '.cpu // {}' <<< "$extra")
if jq -e 'has("enabled")' <<< "$xcpu" > /dev/null; then
	echo "BloxMiner-X: Extra config key ignored (set by BloxMiner-X): cpu.enabled"
	xcpu=$(jq -c 'del(.enabled)' <<< "$xcpu")
fi

ignored=$(jq -r --argjson p "$PROTECTED" '[keys[] | select(. as $k | $p | index($k))] | join(", ")' <<< "$extra")
[[ -n $ignored ]] && echo "BloxMiner-X: Extra config keys ignored (set by BloxMiner-X): $ignored"
rest=$(jq -c --argjson p "$PROTECTED" 'with_entries(select(.key as $k | $p | index($k) | not)) | del(.cpu, .tls, ."1gb-pages", .randomx)' <<< "$extra")
xrx=$(jq -c '.randomx // {}' <<< "$extra")

# write next to the target, validate, then rename: a failure never leaves an empty or partial config
tmp="$CUSTOM_CONFIG_FILENAME.tmp.$$"
if jq -n --arg url "$url" --arg user "$CUSTOM_TEMPLATE" --arg pass "${CUSTOM_PASS:-x}" --arg algo "$algo" \
	--argjson tls "$tls_json" --argjson rest "$rest" --argjson xcpu "$xcpu" --argjson xrx "$xrx" \
	--argjson onegb "$onegb" --arg log "$CUSTOM_LOG_BASENAME.log" \
	'$rest
	 + {cpu: ({enabled: true, "huge-pages": true} + $xcpu),
	    randomx: ($xrx + (if $onegb then {"1gb-pages": true} else {} end)),
	    "donate-level": 0, "donate-over-proxy": 0, "autosave": false, "background": false, "syslog": false,
	    colors: true, "print-time": 60, "log-file": $log,
	    http: {enabled: true, host: "127.0.0.1", port: 4069, restricted: true, "access-token": null},
	    opencl: {enabled: false}, cuda: {enabled: false},
	    pools: [{url: $url, user: $user, pass: $pass, algo: $algo}
	            + (if $tls == null then {} else {tls: $tls} end)]}' > "$tmp" &&
   jq -e --argjson a "$ALGOS" '(.pools | length > 0) and (.pools[0].url | length > 0) and
                               (.pools[0].algo as $g | $a | index($g) != null)' "$tmp" > /dev/null &&
   mv -f "$tmp" "$CUSTOM_CONFIG_FILENAME"; then
	:
else
	rm -f "$tmp"
	fail "BloxMiner-X: could not write $CUSTOM_CONFIG_FILENAME"
fi
