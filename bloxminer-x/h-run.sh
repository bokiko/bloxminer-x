#!/usr/bin/env bash
cd "${BLOX_DIR:-/hive/miners/custom/bloxminer-x}" || exit 1   # BLOX_DIR: tests only
. ./h-manifest.conf || exit 1
mkdir -p "$(dirname "$CUSTOM_LOG_BASENAME")" || exit 1

# CPU gate: x86-64 + AES-NI (XMRig's build adds -maes globally, cmake/flags.cmake) + SSE2 baseline
cpu_ok() {   # CPUINFO overridable for testing
	local f; f=" $(grep -m1 '^flags' "${CPUINFO:-/proc/cpuinfo}" | cut -d: -f2) "
	for x in aes sse2; do [[ $f == *" $x "* ]] || return 1; done
}
if ! cpu_ok; then
	msg="BloxMiner-X needs an x86-64 CPU with AES-NI (RandomX requires AES acceleration)"
	echo "$msg" | tee -a "$CUSTOM_LOG_BASENAME.log"
	message error "$msg" 2>/dev/null
	sleep 60; exit 1
fi

# Huge pages: reserve them before the miner starts, the same way Hive's own xmrig-new integration does
# (/hive/miners/xmrig-new/h-run.sh): reset the sysctl count, then let Hive's own `hugepages` tool re-reserve
# them sized for RandomX (`-erx` when Extra config turned on 1 GB pages, `-rx` otherwise). If that tool is not
# on this rig (older Hive, or running outside Hive for a test), do nothing here - XMRig reserves its own 2 MB
# pages as root on startup either way.
if command -v hugepages > /dev/null 2>&1; then
	sysctl -w vm.nr_hugepages=0 > /dev/null 2>&1
	if jq -e '.randomx."1gb-pages" == true' "$CUSTOM_CONFIG_FILENAME" > /dev/null 2>&1; then
		hugepages -erx
	else
		hugepages -rx
	fi
fi

# XMRig runs directly on the HiveOS screen terminal; its own console output is plain lines + SGR colour, and
# it writes its own log file (config "log-file" = $CUSTOM_LOG_BASENAME.log, XMRig rotates it itself).
# exec: Hive supervises the miner process itself and gets its exit status.
exec ./xmrig -c "$CUSTOM_CONFIG_FILENAME"
