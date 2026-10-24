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

# Startup banner: the same 4x5 core-grid "B" mark as BloxMiner's own blox_banner() (one amber "hot core"), with the
# "-X" in that same amber as in assets/logo-*.svg. It is printed HERE, by the wrapper, and not from inside xmrig,
# because the binary must stay unmodified upstream XMRig 6.26.0 plus donate0.patch (README "exactly one source
# change"; build/build.sh refuses a patch that touches anything but src/donate.h). XMRig's own "ABOUT" header
# still follows below it once exec'd.
# Colour: SGR only when stdout is a terminal (Hive runs the miner in a `screen` pty) AND NO_COLOR is unset or
# empty AND the terminal is known to support colour - `tput colors` when ncurses is present (8+ colours; -1 or
# TERM=dumb -> plain), else a TERM-name fallback (screen*/tmux*/xterm*/linux). The 256-colour palette is used
# when available, otherwise the 8-colour SGR codes BloxMiner itself falls back to (bright-black 100/90 - every
# `screen` passes those through to the real terminal unchanged).
# Log: the plain "##" form is appended to $CUSTOM_LOG_BASENAME.log BEFORE xmrig opens that file, which is what
# makes it survive: XMRig's FileLogWriter tracks its own write offset from the file size at open time (no
# O_APPEND - see h-stats.sh's header), so anything appended to that file AFTER xmrig starts gets overwritten,
# while lines already present at open time are kept and Hive's start-time gzip rotation keeps them with the
# rest of that run's log.
# Failure tolerance: the call below runs in a SUBSHELL, `|| true`, stderr dropped. An unwritable log or a
# closed stdout produce no message and no non-zero status. The subshell matters for one case the `||`
# operators cannot catch: stdout being a pipe whose reader is gone. The first write then raises SIGPIPE, and
# a signal death is not a non-zero status - without the subshell it would kill this wrapper before the exec
# (confirmed on Linux: rc -13, xmrig never started). Inside a subshell only the subshell dies; this shell
# carries on to the exec, and xmrig inherits the default SIGPIPE disposition unchanged (no `trap` here, on
# purpose - XMRig's own signal handling is not this script's business). So the banner can never turn a
# startable miner into a failed start (also under an inherited `bash -e`). What this does NOT cover: a
# synchronous write that BLOCKS (a log path on stalled storage, a FIFO nobody reads) blocks here exactly as it
# would block xmrig's own first log write a moment later - no new failure mode, but not a guarded one either.
blox_banner() {
	local grid=("XXX." "X..X" "XXA." "X..X" "XXX.")   # the "B" core grid, A = hot core
	local side=("" "RandomX CPU miner (Monero / XMR) - 0 % dev fee - GPL-3.0"
	            "based on XMRig 6.26.0 (XMRig, SChernykh and contributors)"
	            "https://github.com/bokiko/bloxminer-x" "")
	local ncolors=0 cell='' hot='' acc='' dim='' bold='' rst=''
	if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
		if command -v tput > /dev/null 2>&1; then
			ncolors=$(tput colors 2>/dev/null) || ncolors=0
			[[ $ncolors =~ ^-?[0-9]+$ ]] || ncolors=0
		else
			case ${TERM:-} in
				*256color*) ncolors=256 ;;
				screen*|tmux*|xterm*|linux) ncolors=8 ;;
			esac
		fi
	fi
	if (( ncolors >= 256 )); then
		cell=$'\e[48;5;245m'; hot=$'\e[48;5;214m'; acc=$'\e[38;5;214m'; dim=$'\e[38;5;245m'
	elif (( ncolors >= 8 )); then
		cell=$'\e[100m'; hot=$'\e[43m'; acc=$'\e[33m'; dim=$'\e[90m'
	else
		ncolors=0
	fi
	(( ncolors )) && { rst=$'\e[0m'; bold=$'\e[1m'; }
	local r c ch row plain
	for r in 0 1 2 3 4; do
		row=" "; plain=" "
		for c in 0 1 2 3; do
			ch=${grid[r]:c:1}
			if [[ $ch == . ]]; then
				row+="  "; plain+="  "
			elif (( ncolors )); then
				if [[ $ch == A ]]; then row+="$hot  $rst"; else row+="$cell  $rst"; fi; plain+="##"
			else
				row+="##"; plain+="##"
			fi
		done
		if (( r == 0 )); then
			row+="    ${bold}Blox${rst}${dim}Miner${rst}${acc}-X${rst} $CUSTOM_VERSION"
			plain+="    BloxMiner-X $CUSTOM_VERSION"
		elif [[ -n ${side[r]} ]]; then
			if (( ncolors && r > 1 )); then row+="    ${dim}${side[r]}${rst}"; else row+="    ${side[r]}"; fi
			plain+="    ${side[r]}"
		fi
		row=${row%"${row##*[! ]}"}; plain=${plain%"${plain##*[! ]}"}   # no trailing blanks from an empty grid cell
		printf '%s\n' "$row" || return 0
		printf '%s\n' "$plain" >> "$CUSTOM_LOG_BASENAME.log" || return 0
	done
	printf '\n'
}
( blox_banner ) 2>/dev/null || true   # subshell: see "Failure tolerance" above (SIGPIPE)

# XMRig runs directly on the HiveOS screen terminal; its own console output is plain lines + SGR colour. Its
# log file (config "log-file" = $CUSTOM_LOG_BASENAME.log) only ever grows while it runs (XMRig writes at its own
# tracked offset, see the banner note above) and XMRig itself never rotates it; the size bound comes from Hive's
# own start-time gzip rotation plus its 15-minute `logtruncateall` cron (20 MB).
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
