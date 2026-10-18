#!/usr/bin/env bash
# Regression test for 1.0.4: xmrig must resolve a pool HOSTNAME without crashing on a host whose glibc and
# NSS setup differ from the build's. 1.0.3 (glibc static) dlopen'ed the host's NSS modules inside getaddrinfo
# and died with SIGSEGV on Ubuntu 24.04 / Mint 22 (glibc 2.39, mdns4_minimal in /etc/nsswitch.conf) before it
# ever connected. The musl build has its own resolver, so it must stay up and reach the connect stage.
# Usage: tests/build/test_dns_resolve.sh <path to xmrig> [host:port]
# Needs network + DNS. BLOX_REQUIRE_MDNS=1 makes a host WITHOUT mdns4_minimal in nsswitch.conf a FAIL (on CI
# the job installs libnss-mdns so the exact 1.0.3 crash condition is present).
set -u
BIN=${1:?path to xmrig}; HP=${2:-github.com:80}
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-62s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-62s FAIL: %s\n' "$1" "$2"; }

if grep -Eq '^hosts:.*mdns4_minimal' /etc/nsswitch.conf; then
	ok "precondition: nsswitch.conf has mdns4_minimal (1.0.3 crash condition)"
elif [[ ${BLOX_REQUIRE_MDNS:-0} == 1 ]]; then
	bad "precondition: nsswitch.conf has mdns4_minimal" "$(grep '^hosts:' /etc/nsswitch.conf)"
else
	echo "note: nsswitch.conf has no mdns4_minimal - this host could not reproduce the 1.0.3 crash anyway"
fi

if readelf -l "$BIN" | grep -q INTERP || readelf -d "$BIN" 2>/dev/null | grep -q NEEDED; then
	bad "xmrig is fully static" "has an interpreter or NEEDED entries"
else
	ok "xmrig is fully static"
fi

LOG=$(mktemp); OUT=$(mktemp); trap 'rm -f "$LOG" "$OUT"' EXIT
# --no-cpu: no mining, only the pool client. 10 s is several reconnect rounds (--retry-pause 1).
# --log-file: stdout to a pipe/file is block-buffered and lost when timeout kills xmrig; its own log is not.
timeout 10 "$BIN" --no-cpu --no-color --retry-pause=1 --log-file="$LOG" -o "$HP" -u x -p x > "$OUT" 2>&1
rc=$?
cat "$OUT" >> "$LOG"
if [[ $rc == 124 ]]; then ok "xmrig still running after 10 s (rc 124 from timeout)"; else bad "xmrig still running after 10 s" "rc=$rc (139 = SIGSEGV, the 1.0.3 bug); log: $(tail -5 "$LOG")"; fi
if grep -q 'DNS error' "$LOG"; then bad "hostname resolved" "$(grep -m1 'DNS error' "$LOG")"; else ok "hostname resolved (no DNS error)"; fi
if grep -Eq "net +${HP//./\\.}" "$LOG"; then ok "reached the connect stage for $HP"; else bad "reached the connect stage for $HP" "no 'net $HP' line; log: $(tail -5 "$LOG")"; fi

echo "passed $pass, failed $fail"
(( fail == 0 ))
