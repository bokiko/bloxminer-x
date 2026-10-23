#!/usr/bin/env bash
# Tests for bloxminer-x/h-run.sh: the startup banner (colour gate, plain copy in the log, failure tolerance),
# the CPU gate, and that xmrig is exec'd with the right config and its exit status comes back unchanged.
# Needs bash 5 and python3 (its `pty` module stands in for Hive's `screen` pty, portably on Linux and macOS).
# Usage: tests/hive/test_h_run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); PKGSRC=$(cd "$HERE/../../bloxminer-x" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-66s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-66s FAIL: %s\n' "$1" "$2"; }

export BLOX_DIR=$T/pkg
mkdir -p "$BLOX_DIR" "$T/bin"
cp "$PKGSRC"/h-run.sh "$BLOX_DIR"/
sed -e "s#^CUSTOM_CONFIG_FILENAME=.*#CUSTOM_CONFIG_FILENAME=$T/config.json#" \
    -e "s#^CUSTOM_LOG_BASENAME=.*#CUSTOM_LOG_BASENAME=$T/log/bloxminer-x#" "$PKGSRC/h-manifest.conf" > "$BLOX_DIR/h-manifest.conf"
VER=$(sed -n 's/^CUSTOM_VERSION=//p' "$PKGSRC/h-manifest.conf")
LOG=$T/log/bloxminer-x.log
printf 'flags\t\t: fpu aes sse2 avx2\n' > "$T/cpuinfo.ok"
printf 'flags\t\t: fpu sse2 avx2\n'     > "$T/cpuinfo.noaes"
export CPUINFO=$T/cpuinfo.ok

# a fake xmrig: records how it was called, exits with $FAKE_RC. exec replaces h-run.sh with it, so its status IS
# h-run.sh's status.
cat > "$BLOX_DIR/xmrig" <<'X'
#!/usr/bin/env bash
echo "FAKE_XMRIG $*"
exit "${FAKE_RC:-0}"
X
chmod +x "$BLOX_DIR/xmrig"
# stubs on PATH: `hugepages` (Hive's tool) records its call; `sleep` so the CPU-gate's `sleep 60` is instant
printf '#!/usr/bin/env bash\necho "HUGEPAGES $*"\n' > "$T/bin/hugepages"
printf '#!/usr/bin/env bash\necho "SLEEP $*"\n'     > "$T/bin/sleep"
chmod +x "$T/bin/hugepages" "$T/bin/sleep"
export PATH=$T/bin:$PATH

ESC=$'\e'
reset_log() { rm -rf "$T/log"; mkdir -p "$T/log"; }
run()     { out=$(bash "$BLOX_DIR/h-run.sh" 2>&1); rc=$?; }                   # stdout redirected (not a tty)
run_pty() {   # env assignments... -> runs h-run.sh with stdout on a pty, like Hive's screen session
	out=$(env "$@" python3 -c 'import pty,sys; pty.spawn(sys.argv[1:])' bash "$BLOX_DIR/h-run.sh" 2>/dev/null | tr -d '\r'); rc=$?
}
has()  { grep -qF -- "$2" <<< "$1"; }
plain_rows() {   # the five plain banner rows, in order
	printf '%s\n' " ######      BloxMiner-X $VER" \
	              " ##    ##    RandomX CPU miner (Monero / XMR) - 0 % dev fee - GPL-3.0" \
	              " ######      based on XMRig 6.26.0 (XMRig, SChernykh and contributors)" \
	              " ##    ##    https://github.com/bokiko/bloxminer-x" \
	              " ######"
}

# ------------------------------------------------------------------ plain run (stdout redirected)
reset_log; echo "OLDER LINE" > "$LOG"
run
if [[ $rc == 0 ]] && [[ $(grep -v '^HUGEPAGES' <<< "$out" | head -5) == "$(plain_rows)" ]]; then ok "redirected stdout: the five plain banner rows come first"; else bad "redirected stdout: the five plain banner rows come first" "rc=$rc out=$out"; fi
if ! has "$out" "$ESC"; then ok "redirected stdout: no SGR escapes"; else bad "redirected stdout: no SGR escapes" "out=$(cat -v <<< "$out")"; fi
if [[ $(tail -1 <<< "$out") == "FAKE_XMRIG -c $T/config.json" ]]; then ok "xmrig is exec'd last, with -c <CUSTOM_CONFIG_FILENAME>"; else bad "xmrig is exec'd last, with -c <CUSTOM_CONFIG_FILENAME>" "out=$out"; fi
if has "$out" "HUGEPAGES -rx" && [[ $(grep -n 'HUGEPAGES\|BloxMiner-X' <<< "$out" | head -1) == 1:HUGEPAGES* ]]; then ok "hugepages -rx runs before the banner and the exec"; else bad "hugepages -rx runs before the banner and the exec" "out=$out"; fi
if [[ $(cat "$LOG") == "$(printf 'OLDER LINE\n'; plain_rows)" ]]; then ok "log: existing content kept, five plain rows appended, no escapes"; else bad "log: existing content kept, five plain rows appended, no escapes" "log=$(cat -v "$LOG")"; fi

reset_log; FAKE_RC=7 run
if [[ $rc == 7 ]]; then ok "xmrig's exit status is h-run.sh's exit status"; else bad "xmrig's exit status is h-run.sh's exit status" "rc=$rc"; fi

# ------------------------------------------------------------------ colour gate on a pty
reset_log; run_pty TERM=xterm-256color
if has "$out" "${ESC}[48;5;214m" && has "$out" "${ESC}[48;5;245m" && has "$out" "${ESC}[38;5;214m-X"; then ok "pty, 256-colour TERM: 256-colour palette, amber hot core and -X"; else bad "pty, 256-colour TERM: 256-colour palette, amber hot core and -X" "out=$(cat -v <<< "$out")"; fi
if has "$out" "BloxMiner-X $VER" || has "$out" "${ESC}[1mBlox"; then ok "pty: wordmark and version present"; else bad "pty: wordmark and version present" "out=$(cat -v <<< "$out")"; fi
if ! grep -q "$ESC" "$LOG" && [[ $(cat "$LOG") == "$(plain_rows)" ]]; then ok "pty: the log still gets the plain rows only"; else bad "pty: the log still gets the plain rows only" "log=$(cat -v "$LOG")"; fi
if [[ $(tail -1 <<< "$out") == "FAKE_XMRIG -c $T/config.json" ]]; then ok "pty: xmrig still exec'd after the banner"; else bad "pty: xmrig still exec'd after the banner" "out=$out"; fi

reset_log; run_pty TERM=screen
if has "$out" "${ESC}[43m" && has "$out" "${ESC}[100m" && ! has "$out" "48;5;"; then ok "pty, TERM=screen (8 colours): 8-colour SGR, no 256-colour codes"; else bad "pty, TERM=screen (8 colours): 8-colour SGR, no 256-colour codes" "out=$(cat -v <<< "$out")"; fi

reset_log; run_pty TERM=dumb
if ! has "$out" "$ESC" && has "$out" "BloxMiner-X $VER"; then ok "pty, TERM=dumb: plain banner, no escapes"; else bad "pty, TERM=dumb: plain banner, no escapes" "out=$(cat -v <<< "$out")"; fi

reset_log; run_pty TERM=xterm-256color NO_COLOR=1
if ! has "$out" "$ESC" && has "$out" "BloxMiner-X $VER"; then ok "pty, NO_COLOR=1: plain banner"; else bad "pty, NO_COLOR=1: plain banner" "out=$(cat -v <<< "$out")"; fi
reset_log; run_pty TERM=xterm-256color NO_COLOR=
if has "$out" "$ESC"; then ok "pty, NO_COLOR set but empty: colour stays (no-color.org semantics)"; else bad "pty, NO_COLOR set but empty: colour stays (no-color.org semantics)" "out=$(cat -v <<< "$out")"; fi

# tput failing (exit 1, no output) and tput absent, both on a `screen` pty
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tput"; chmod +x "$T/bin/tput"
reset_log; run_pty TERM=screen
if has "$out" "BloxMiner-X $VER" && ! has "$out" "$ESC" && [[ $(tail -1 <<< "$out") == FAKE_XMRIG* ]]; then ok "pty, tput fails: plain banner, miner still starts"; else bad "pty, tput fails: plain banner, miner still starts" "out=$(cat -v <<< "$out")"; fi
rm "$T/bin/tput"
MINPATH=$T/minbin; mkdir -p "$MINPATH"
for tool in bash grep cut mkdir dirname env tr head tail cat python3; do ln -sf "$(command -v "$tool")" "$MINPATH/$tool"; done
reset_log; run_pty PATH="$MINPATH" TERM=screen-256color
if has "$out" "${ESC}[48;5;214m" && [[ $(tail -1 <<< "$out") == FAKE_XMRIG* ]]; then ok "pty, no tput on PATH, TERM=screen-256color: TERM-name fallback -> 256 colours"; else bad "pty, no tput on PATH, TERM=screen-256color: TERM-name fallback -> 256 colours" "out=$(cat -v <<< "$out")"; fi
reset_log; run_pty PATH="$MINPATH" TERM=screen
if has "$out" "${ESC}[43m" && ! has "$out" "48;5;"; then ok "pty, no tput on PATH, TERM=screen: TERM-name fallback -> 8 colours"; else bad "pty, no tput on PATH, TERM=screen: TERM-name fallback -> 8 colours" "out=$(cat -v <<< "$out")"; fi
reset_log; run_pty PATH="$MINPATH" TERM=vt100
if ! has "$out" "$ESC" && has "$out" "BloxMiner-X $VER"; then ok "pty, no tput on PATH, unknown TERM: plain"; else bad "pty, no tput on PATH, unknown TERM: plain" "out=$(cat -v <<< "$out")"; fi

# ------------------------------------------------------------------ failure tolerance
reset_log; mkdir "$LOG"   # the log path is a directory: every append fails
run
if [[ $rc == 0 ]] && [[ $(tail -1 <<< "$out") == "FAKE_XMRIG -c $T/config.json" ]] && has "$out" "BloxMiner-X $VER"; then ok "unwritable log: banner still on stdout, miner still starts, rc 0"; else bad "unwritable log: banner still on stdout, miner still starts, rc 0" "rc=$rc out=$out"; fi
if ! has "$out" "Is a directory" && ! has "$out" "rror"; then ok "unwritable log: no error text leaks to the screen"; else bad "unwritable log: no error text leaks to the screen" "out=$out"; fi
out=$(bash -e "$BLOX_DIR/h-run.sh" 2>&1); rc=$?
if [[ $rc == 0 ]] && [[ $(tail -1 <<< "$out") == FAKE_XMRIG* ]]; then ok "unwritable log under bash -e: miner still starts"; else bad "unwritable log under bash -e: miner still starts" "rc=$rc out=$out"; fi
rmdir "$LOG"

# ------------------------------------------------------------------ no banner when the start is refused
reset_log; CPUINFO=$T/cpuinfo.noaes run
if [[ $rc == 1 ]] && has "$out" "needs an x86-64 CPU with AES-NI" && ! has "$out" "BloxMiner-X $VER" && ! has "$out" "FAKE_XMRIG" && has "$out" "SLEEP 60"; then ok "CPU without AES-NI: error, no banner, no exec, rc 1"; else bad "CPU without AES-NI: error, no banner, no exec, rc 1" "rc=$rc out=$out"; fi
if ! grep -q '######' "$LOG" && grep -q "AES-NI" "$LOG"; then ok "CPU without AES-NI: only the error reaches the log"; else bad "CPU without AES-NI: only the error reaches the log" "log=$(cat "$LOG" 2>&1)"; fi
reset_log; mv "$BLOX_DIR/xmrig" "$BLOX_DIR/xmrig.away"; run; mv "$BLOX_DIR/xmrig.away" "$BLOX_DIR/xmrig"
if [[ $rc == 1 ]] && has "$out" "xmrig: No such file or directory" && ! has "$out" "BloxMiner-X $VER"; then ok "missing xmrig: error, no banner, rc 1"; else bad "missing xmrig: error, no banner, rc 1" "rc=$rc out=$out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
