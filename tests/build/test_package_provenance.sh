#!/usr/bin/env bash
# Tests build/package.sh's helper-source provenance check: it must refuse to package if any helper source
# file (bloxsense/*, the Hive h-*.sh/h-manifest.conf, or the build scripts/patch) has changed since
# build/build.sh recorded its sha256 - so a package can never ship sources that do not match its own binaries.
# This does NOT run the real build/build.sh (needs root, network and several minutes to compile); instead it
# hand-crafts a build.provenance whose helper hashes are computed from THIS repo's real, current files - the
# same way build/build.sh itself computes them - which proves package.sh's check is real, not a rubber stamp.
# It DOES run the real build/package.sh end to end (including its network clone of xmrig for the -src bundle),
# since ai02 has internet access; only tampering makes it fail fast, before any network access happens.
# Usage: tests/build/test_package_provenance.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '%-58s ok\n' "$1"; }
bad() { fail=$((fail+1)); printf '%-58s FAIL: %s\n' "$1" "$2"; }

# Work on a disposable copy of the repo so tampering here never touches the real tree.
REPO="$T/repo"; mkdir -p "$REPO"
cp -R "$ROOT"/bloxsense "$ROOT"/bloxminer-x "$ROOT"/build "$ROOT"/LICENSE "$ROOT"/LICENSES "$REPO"/

HELPERS=(bloxsense/blox.h bloxsense/blox_sys.cpp bloxsense/bloxsense.cpp
         bloxminer-x/h-config.sh bloxminer-x/h-run.sh bloxminer-x/h-stats.sh bloxminer-x/h-manifest.conf
         build/build.sh build/package.sh build/donate0.patch)

fake_out() {   # (re)writes $T/out: fake xmrig/bloxsense "binaries" + a build.provenance matching $REPO's CURRENT files
	rm -rf "$T/out"; mkdir -p "$T/out"
	echo "fake xmrig binary $RANDOM" > "$T/out/xmrig"
	echo "fake bloxsense binary $RANDOM" > "$T/out/bloxsense"
	{
		echo "upstream=https://github.com/xmrig/xmrig"
		echo "upstream_tag=v6.26.0"
		echo "upstream_commit=b2ca72480c58d197e18c885d9fc1a0c8d517e60a"
		echo "patch_sha256=$(sha256sum "$REPO/build/donate0.patch" | cut -d' ' -f1)"
		echo "dep.libuv.version=1.51.0"; echo "dep.libuv.url=https://dist.libuv.org/dist/v1.51.0/libuv-v1.51.0.tar.gz"
		echo "dep.libuv.sha256=5f0557b90b1106de71951a3c3931de5e0430d78da1d9a10287ebc7a3f78ef8eb"
		echo "dep.hwloc.version=2.12.1"; echo "dep.hwloc.url=https://download.open-mpi.org/release/hwloc/v2.12/hwloc-2.12.1.tar.gz"
		echo "dep.hwloc.sha256=ffa02c3a308275a9339fbe92add054fac8e9a00cb8fe8c53340094012cb7c633"
		echo "dep.openssl.version=3.5.9"; echo "dep.openssl.url=https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz"
		echo "dep.openssl.sha256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
		echo "source_date_epoch=1774703046"
		echo "cflags=-O2"; echo "cxxflags=-O2"
		echo "compiler.gcc=fake"; echo "compiler.gxx=fake"; echo "compiler.cmake=fake"
		echo "os=fake test fixture"
		echo "xmrig_sha256=$(sha256sum "$T/out/xmrig" | cut -d' ' -f1)"
		echo "bloxsense_sha256=$(sha256sum "$T/out/bloxsense" | cut -d' ' -f1)"
		for h in "${HELPERS[@]}"; do echo "helper.$h.sha256=$(sha256sum "$REPO/$h" | cut -d' ' -f1)"; done
	} > "$T/out/build.provenance"
}

run_package() { rm -rf "$T/pkgout"; mkdir -p "$T/pkgout"; ( cd "$REPO" && bash build/package.sh "$T/out" "$T/pkgout" ) > "$T/pkg.out" 2>&1; }

fake_out
if run_package && [[ -f $T/pkgout/bloxminer-x-1.0.3.tar.gz && -f $T/pkgout/bloxminer-x-1.0.3-src.tar.gz ]]; then
	ok "baseline: untampered sources -> package.sh succeeds, both artefacts produced"
else
	bad "baseline: untampered sources -> package.sh succeeds, both artefacts produced" "$(cat "$T/pkg.out")"
fi

echo "// tampered $RANDOM" >> "$REPO/bloxminer-x/h-stats.sh"   # provenance still has the OLD hash
if ! run_package && grep -q "bloxminer-x/h-stats.sh does not match its recorded source hash" "$T/pkg.out"; then
	ok "tampered h-stats.sh (after build) -> package.sh refuses"
else
	bad "tampered h-stats.sh (after build) -> package.sh refuses" "rc=$? out=$(cat "$T/pkg.out")"
fi
if [[ ! -f $T/pkgout/bloxminer-x-1.0.3.tar.gz ]]; then ok "tampered h-stats.sh -> no package written"; else bad "tampered h-stats.sh -> no package written" "package exists"; fi

fake_out   # re-snapshot: now the (tampered) content IS what provenance expects -> must succeed again
if run_package; then ok "re-snapshotted provenance after edit -> succeeds again (checks current content, not a fixed list)"; else bad "re-snapshotted provenance after edit -> succeeds again" "$(cat "$T/pkg.out")"; fi

fake_out
echo "; tampered bloxsense $RANDOM" >> "$REPO/bloxsense/blox_sys.cpp"
if ! run_package && grep -q "bloxsense/blox_sys.cpp does not match its recorded source hash" "$T/pkg.out"; then
	ok "tampered blox_sys.cpp -> package.sh refuses"
else
	bad "tampered blox_sys.cpp -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

fake_out
echo "# tampered patch" >> "$REPO/build/donate0.patch"
if ! run_package && grep -qi "donate0.patch" "$T/pkg.out"; then
	ok "tampered donate0.patch -> package.sh refuses (patch_sha256 mismatch)"
else
	bad "tampered donate0.patch -> package.sh refuses (patch_sha256 mismatch)" "out=$(cat "$T/pkg.out")"
fi

fake_out
sed -i '/^helper\.bloxminer-x\/h-run\.sh\.sha256=/d' "$T/out/build.provenance"   # simulate an old-style provenance
if ! run_package && grep -q "bloxminer-x/h-run.sh: expected by build/build.sh's own current HELPERS array but missing" "$T/pkg.out"; then
	ok "missing helper hash in provenance -> package.sh refuses"
else
	bad "missing helper hash in provenance -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

# ---- pin verification: upstream/tag/commit and dependency versions+hashes must match build/build.sh's OWN
# pinned literals, not just be self-consistent with the provenance file alone (an outdir built from some other
# xmrig revision or dependency set could otherwise pass every self-consistency check above and still ship).
fake_out
sed -i.bak 's|^upstream=.*|upstream=https://github.com/attacker/xmrig|' "$T/out/build.provenance"
if ! run_package && grep -qF "pinned UPSTREAM" "$T/pkg.out"; then
	ok "tampered provenance upstream -> package.sh refuses"
else
	bad "tampered provenance upstream -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

fake_out
sed -i.bak 's/^upstream_tag=.*/upstream_tag=v99.0.0/' "$T/out/build.provenance"
if ! run_package && grep -qF "pinned TAG" "$T/pkg.out"; then
	ok "tampered provenance upstream_tag -> package.sh refuses"
else
	bad "tampered provenance upstream_tag -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

fake_out
sed -i.bak 's/^upstream_commit=.*/upstream_commit=0000000000000000000000000000000000000000/' "$T/out/build.provenance"
if ! run_package && grep -qF "pinned COMMIT" "$T/pkg.out"; then
	ok "tampered provenance upstream_commit -> package.sh refuses"
else
	bad "tampered provenance upstream_commit -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

fake_out
sed -i.bak 's/^dep.libuv.version=.*/dep.libuv.version=9.9.9/' "$T/out/build.provenance"
if ! run_package && grep -qF "pinned UV_VER" "$T/pkg.out"; then
	ok "tampered provenance dep.libuv.version -> package.sh refuses"
else
	bad "tampered provenance dep.libuv.version -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

fake_out
sed -i.bak 's/^dep.hwloc.sha256=.*/dep.hwloc.sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$T/out/build.provenance"
if ! run_package && grep -qF "pinned HWLOC_SHA256" "$T/pkg.out"; then
	ok "tampered provenance dep.hwloc.sha256 -> package.sh refuses"
else
	bad "tampered provenance dep.hwloc.sha256 -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

fake_out
sed -i.bak 's/^dep.openssl.version=.*/dep.openssl.version=9.9.9/' "$T/out/build.provenance"
if ! run_package && grep -qF "pinned SSL_VER" "$T/pkg.out"; then
	ok "tampered provenance dep.openssl.version -> package.sh refuses"
else
	bad "tampered provenance dep.openssl.version -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

# ---- "Require every expected helper provenance entry" - the gate must require EVERY currently-expected
# helper (derived from build/build.sh's own HELPERS array) to be present in the provenance, not just "at least
# one helper.*.sha256 line matches". Deletes ONLY h-run.sh's own line - every other helper stays correctly
# recorded - and asserts package.sh refuses, naming the specific missing helper.
fake_out
sed -i.bak '/^helper\.bloxminer-x\/h-run\.sh\.sha256=/d' "$T/out/build.provenance"
if ! run_package && grep -qF "bloxminer-x/h-run.sh" "$T/pkg.out" && grep -qF "missing from" "$T/pkg.out"; then
	ok "provenance with exactly ONE helper.*.sha256 line deleted (others still valid) -> package.sh refuses"
else
	bad "provenance with exactly ONE helper.*.sha256 line deleted (others still valid) -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

# ---- an EXTRA/unknown helper.*.sha256 entry - one that does not correspond to anything build/build.sh's own
# HELPERS array currently lists (e.g. a stale leftover from a renamed/removed file, or a hand-edited addition)
# - must also refuse, not silently hash-check it and report fine. The extra entry's own hash is deliberately
# CORRECT (sha256 of a real file in this repo) - the refusal must come from it not being an expected helper at
# all, never from a coincidental hash mismatch.
fake_out
# LICENSE: a real file that DOES exist in the test's own disposable $REPO copy (so the "does this file even
# exist" check passes) but is NOT one of build/build.sh's HELPERS entries - the refusal below must come from
# it not being an expected helper at all, never from a missing file or a coincidental hash mismatch.
printf 'helper.LICENSE.sha256=%s\n' "$(sha256sum "$REPO/LICENSE" | cut -d' ' -f1)" >> "$T/out/build.provenance"
if ! run_package && grep -qF "LICENSE" "$T/pkg.out" && grep -qF "not in build/build.sh's own current HELPERS array" "$T/pkg.out"; then
	ok "provenance with an EXTRA/unknown helper.*.sha256 entry -> package.sh refuses"
else
	bad "provenance with an EXTRA/unknown helper.*.sha256 entry -> package.sh refuses" "out=$(cat "$T/pkg.out")"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
