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

# Huge pages: reserve 2 MB pages before the miner starts, the same way Hive's own xmrig-new integration does
# (/hive/miners/xmrig-new/h-run.sh) - run Hive's own `hugepages -rx` tool if it exists on this rig. If it is
# not present (older Hive, or running outside Hive for a test), do nothing here - XMRig reserves its own 2 MB
# pages as root on startup either way. 1 GB pages are XMRig's own concern: h-config.sh only ever passes
# "randomx": {"1gb-pages": true} after its own NUMA free-memory check, and XMRig reserves/falls back to 2 MB
# pages itself at runtime (R5') - h-run.sh takes no separate action for it.
if command -v hugepages > /dev/null 2>&1; then
	hugepages -rx
fi

# A missing/non-executable binary is checked explicitly, rather than just letting `exec` below fail on its
# own, because a bash `exec` that fails to find its target (non-interactively) exits WITHOUT printing anything
# useful of its own - confirmed directly (a minimal repro: `exec ./missing` just prints
# "<path>: No such file or directory" from bash itself, with no chance for this script to add context first).
# This check exists to produce a clear, Hive-visible message (both to the log and via `message error`) before
# that happens, not to change what the exec itself would eventually have done.
if [[ ! -x ./xmrig ]]; then
	msg="$PWD/xmrig: No such file or directory"
	echo "$msg" | tee -a "$CUSTOM_LOG_BASENAME.log"
	message error "$msg" 2>/dev/null
	exit 1
fi

# XMRig runs directly on the HiveOS screen terminal; its own console output is plain lines + SGR colour. Its
# log file (config "log-file" = $CUSTOM_LOG_BASENAME.log) is append-only - XMRig itself never rotates it; the
# size bound comes from Hive's own start-time gzip rotation plus its 15-minute `logtruncateall` cron (20 MB).
# exec: Hive supervises the miner process itself and gets its exit status. On SUCCESS this replaces the
# process image outright. `shopt -s execfail` covers the one remaining failure mode the `-x` check above
# cannot catch: a present, executable, but not actually runnable binary (corrupt or wrong-architecture ELF) -
# without it, a failed exec in a non-interactive shell terminates this process immediately with only bash's
# own generic message; with it, a failed exec instead returns control here, so this script can print a clearer
# error itself before exiting non-zero. Unlike BloxMiner v3's RandomX engine, there is no huge-page ownership
# record to roll back here (BloxMiner-X never tracks or restores a prior vm.nr_hugepages value - see README.md
# "Switching back to Verus" for the manual procedure), so no rollback trap is needed either; this exists purely
# for a clearer error message on an otherwise-silent failure mode.
shopt -s execfail
# shellcheck disable=SC2093   # intentional: execfail above means a FAILED exec returns here instead of ending
# the script - the explicit error message and exit below this exec is the whole point of the change above, not
# dead code shellcheck's own (execfail-unaware) heuristic assumes it to be.
exec ./xmrig -c "$CUSTOM_CONFIG_FILENAME"
rc=$?
msg="BloxMiner-X: exec of $PWD/xmrig failed (rc=$rc) - present and executable but not runnable (corrupt or wrong-architecture binary?)"
echo "$msg" | tee -a "$CUSTOM_LOG_BASENAME.log"
message error "$msg" 2>/dev/null
exit "$rc"
