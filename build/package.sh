#!/usr/bin/env bash
# Assemble the HiveOS custom-miner release artefacts (deterministic tars):
#   bloxminer-x-<ver>.tar.gz      - the binary package: xmrig, bloxsense, h-*.sh, licenses, build.provenance
#   bloxminer-x-<ver>-src.tar.gz  - GPL "Corresponding Source": XMRig v6.26.0 with donate0.patch already
#                                   applied, plus the build scripts, Hive scripts, bloxsense sources and
#                                   licenses needed to rebuild it - anyone can inspect or rebuild the modified
#                                   binaries from this alone, without cloning anything or trusting a network fetch.
# Usage: build/package.sh <outdir built by build/build.sh> [outdir for the packages]
# <outdir> must contain xmrig, bloxsense and build.provenance (written by build/build.sh, including the sha256
# of every helper source file AS THEY WERE AT BUILD TIME). This script recomputes those same hashes from the
# files it is about to ship and REFUSES to package on any mismatch - a helper source edited after the build
# but before packaging can never ship next to a binary that does not match it.
set -euo pipefail
IN=${1:?path to the outdir built by build/build.sh}; IN=$(cd "$IN" && pwd)
OUT=${2:-$PWD}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PROV="$IN/build.provenance"
[[ -f $PROV ]] || { echo "missing $PROV (build with build/build.sh)"; exit 1; }
p() { sed -n "s|^$1=||p" "$PROV"; }   # | delimiter: some keys (helper.<path>) contain /

[[ $(p xmrig_sha256) == "$(sha256sum "$IN/xmrig" | cut -d' ' -f1)" ]] || { echo "$PROV does not describe $IN/xmrig (sha256 differs)"; exit 1; }
[[ $(p bloxsense_sha256) == "$(sha256sum "$IN/bloxsense" | cut -d' ' -f1)" ]] || { echo "$PROV does not describe $IN/bloxsense (sha256 differs)"; exit 1; }
[[ $(p patch_sha256) == "$(sha256sum "$HERE/donate0.patch" | cut -d' ' -f1)" ]] || { echo "binary was built from a different donate0.patch"; exit 1; }
VER=$(sed -n 's/^CUSTOM_VERSION=//p' "$ROOT/bloxminer-x/h-manifest.conf")
UPSTREAM=$(p upstream); TAG=$(p upstream_tag); COMMIT=$(p upstream_commit)
# BLOXMINER_X_REPO_COMMIT: override when packaging on a host that has this build's output but not the git
# checkout itself (e.g. a build/package server without .git) - otherwise read from the local repo. This is
# informational only (recorded in SOURCE.md), unlike the helper hashes below, which are enforced.
REPO_COMMIT=${BLOXMINER_X_REPO_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}

# "helper" source files (everything BloxMiner-X adds on top of XMRig): build/build.sh recorded each one's
# sha256 in $PROV at build time (helper.<path>.sha256=...). Recompute every one now and refuse to package on
# any mismatch, so a package can never ship a helper source that does not match what the binary was built with.
HELPERS=(bloxsense/blox.h bloxsense/blox_sys.cpp bloxsense/bloxsense.cpp
         bloxminer-x/h-config.sh bloxminer-x/h-run.sh bloxminer-x/h-stats.sh bloxminer-x/h-manifest.conf
         build/build.sh build/package.sh build/donate0.patch)
for h in "${HELPERS[@]}"; do
	want=$(p "helper.$h.sha256")
	[[ -n $want ]] || { echo "build.provenance has no helper.$h.sha256 - rebuild with the current build/build.sh"; exit 1; }
	got=$(sha256sum "$ROOT/$h" | cut -d' ' -f1)
	[[ $got == "$want" ]] || { echo "$h changed since the build: provenance has $want, file is now $got - rebuild with build/build.sh before packaging"; exit 1; }
done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# An augmented copy of build.provenance: the original build-time facts (from build/build.sh, already including
# every verified helper.*.sha256) plus the one thing that only exists at packaging time - this git repo's own
# commit. Never mutates $PROV itself: build/build.sh's own provenance file stays exactly what it wrote.
AUGPROV="$W/build.provenance"
cp "$PROV" "$AUGPROV"
echo "repo_commit=$REPO_COMMIT" >> "$AUGPROV"

gen_source_md() {   # $1 = "binary" or "src" - only the how-to-rebuild paragraph differs
	cat <<SRC
BloxMiner-X $VER - corresponding source (GPL-3.0)

BloxMiner-X is XMRig ($UPSTREAM) at tag $TAG, commit $COMMIT,
with build/donate0.patch applied (the ONLY source change: src/donate.h kDefaultDonateLevel and
kMinimumDonateLevel, from 1 to 0 - a 0% developer donation instead of XMRig's default 1%), built by
build/build.sh: https://github.com/xmrig/xmrig/tree/$TAG

xmrig sha256            $(p xmrig_sha256)
bloxsense sha256        $(p bloxsense_sha256)
donate0.patch sha256    $(p patch_sha256)
compiler (xmrig)        $(p compiler.gcc)
compiler (bloxsense)    $(p compiler.gxx)
cmake                   $(p compiler.cmake)
SOURCE_DATE_EPOCH       $(p source_date_epoch)
build OS                $(p os)
bloxminer-x repo commit $REPO_COMMIT

Static dependencies (built from source by build/build.sh, sha256-pinned):
  libuv   $(p dep.libuv.version)    $(p dep.libuv.sha256)   $(p dep.libuv.url)
  hwloc   $(p dep.hwloc.version)    $(p dep.hwloc.sha256)   $(p dep.hwloc.url)
  OpenSSL $(p dep.openssl.version)  $(p dep.openssl.sha256) $(p dep.openssl.url)

Helper source files (everything BloxMiner-X adds on top of XMRig) - sha256 recorded at build time and
verified unchanged by build/package.sh before this bundle was assembled:
$(for h in "${HELPERS[@]}"; do printf '  %-40s %s\n' "$h" "$(sha256sum "$ROOT/$h" | cut -d' ' -f1)"; done)
SRC
	if [[ $1 == src ]]; then
		cat <<'SRC2'

This is the SOURCE bundle: xmrig/ already contains the upstream tree at the commit above with
build/donate0.patch applied, so no network access or upstream checkout is needed to inspect or rebuild it -
this is the GPL-3.0 "Corresponding Source" for the binaries in the companion bloxminer-x-<ver>.tar.gz package.
bloxminer-x/ here holds the HiveOS integration scripts this bundle's own build/package.sh needs to assemble a
full binary package (it copies them from here, the same files shipped in the companion binary package).
To rebuild the binaries from this bundle: run build/build.sh (Ubuntu 22.04, as root, in a container/chroot);
it clones xmrig fresh over the network and re-applies the patch itself (verifying the tag's commit and the
patch's sha256 match what is recorded above), so the result is the same as building from the xmrig/ directory
included here. bloxsense/ here is built the same way build/build.sh builds it: plain -O2, statically linked,
from blox_sys.cpp/blox.h/bloxsense.cpp.
SRC2
	else
		cat <<SRC3

To rebuild bit-for-bit: run build/build.sh as root in a stock Ubuntu 22.04 container/chroot; it clones xmrig
at the tag above, verifies the commit, applies donate0.patch, builds the three static dependencies above from
the same pinned, checksummed tarballs, and builds xmrig (cmake Release, BUILD_STATIC=ON, no OpenCL/CUDA) and
bloxsense (plain -O2) exactly as done here. The full GPL "Corresponding Source" (XMRig with the patch already
applied, plus these build scripts and the Hive integration scripts) is published alongside this package as
bloxminer-x-$VER-src.tar.gz.

bloxsense/bloxsense.cpp is new (BloxMiner-X's own code); bloxsense/blox.h and bloxsense/blox_sys.cpp are
copied byte-identical from BloxMiner 2.1.0 (bokiko/bloxminer, GPL-3.0) - see that file's header comment.

Licenses: XMRig and bloxsense are GPL-3.0 (LICENSE). Statically linked dependencies: libuv (MIT),
hwloc (BSD-3-Clause), OpenSSL 3 (Apache-2.0) - see LICENSES/.
SRC3
	fi
}

# ---------------------------------------------------------------- binary package
D="$W/bloxminer-x"; mkdir -p "$D/LICENSES"
cp "$ROOT"/bloxminer-x/h-config.sh "$ROOT"/bloxminer-x/h-run.sh "$ROOT"/bloxminer-x/h-stats.sh "$ROOT"/bloxminer-x/h-manifest.conf "$D/"
cp "$IN/xmrig" "$D/xmrig"; cp "$IN/bloxsense" "$D/bloxsense"
cp "$ROOT/LICENSE" "$D/LICENSE"
cp "$ROOT"/LICENSES/LICENSE.libuv "$ROOT"/LICENSES/LICENSE.hwloc "$ROOT"/LICENSES/LICENSE.openssl "$D/LICENSES/"
cp "$AUGPROV" "$D/build.provenance"
gen_source_md binary > "$D/SOURCE.md"
chmod 755 "$D" "$D"/*.sh "$D/xmrig" "$D/bloxsense"
chmod 644 "$D/h-manifest.conf" "$D/LICENSE" "$D/LICENSES"/* "$D/SOURCE.md" "$D/build.provenance"
TGZ="bloxminer-x-$VER.tar.gz"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-09-28 00:00:00Z' -C "$W" -cf - bloxminer-x | gzip -n -9 > "$OUT/$TGZ"

# ---------------------------------------------------------------- source package: re-clone + re-verify + re-patch
SRCCLONE="$W/xmrig-src"
git clone -q --branch "$TAG" "$UPSTREAM" "$SRCCLONE"
FULL=$(git -C "$SRCCLONE" rev-parse HEAD)
[[ $FULL == "$COMMIT" ]] || { echo "xmrig $TAG resolved to $FULL, expected $COMMIT - refusing to package"; exit 1; }
(cd "$SRCCLONE" && patch -p1 < "$HERE/donate0.patch" > /dev/null)
DIFF_FILES=$(git -C "$SRCCLONE" diff --name-only)
[[ $DIFF_FILES == "src/donate.h" ]] || { echo "patch touched more than src/donate.h: $DIFF_FILES"; exit 1; }
rm -rf "$SRCCLONE/.git"

SDNAME="bloxminer-x-$VER-src"
SD="$W/$SDNAME"; mkdir -p "$SD/build" "$SD/bloxsense" "$SD/bloxminer-x" "$SD/LICENSES"
mv "$SRCCLONE" "$SD/xmrig"
cp "$HERE"/build.sh "$HERE"/package.sh "$HERE"/donate0.patch "$SD/build/"
cp "$ROOT"/bloxsense/blox.h "$ROOT"/bloxsense/blox_sys.cpp "$ROOT"/bloxsense/bloxsense.cpp "$SD/bloxsense/"
cp "$ROOT"/bloxminer-x/h-config.sh "$ROOT"/bloxminer-x/h-run.sh "$ROOT"/bloxminer-x/h-stats.sh "$ROOT"/bloxminer-x/h-manifest.conf "$SD/bloxminer-x/"
cp "$ROOT/LICENSE" "$SD/LICENSE"
cp "$ROOT"/LICENSES/LICENSE.libuv "$ROOT"/LICENSES/LICENSE.hwloc "$ROOT"/LICENSES/LICENSE.openssl "$SD/LICENSES/"
cp "$AUGPROV" "$SD/build.provenance"
gen_source_md src > "$SD/SOURCE.md"
chmod -R u+rwX,go+rX,go-w "$SD"
SRCTGZ="$SDNAME.tar.gz"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-09-28 00:00:00Z' -C "$W" -cf - "$SDNAME" | gzip -n -9 > "$OUT/$SRCTGZ"

cd "$OUT"
{
	sha256sum "$TGZ" "$SRCTGZ"
	(cd "$W" && find bloxminer-x -type f | sort | xargs sha256sum)
} > SHA256SUMS
cat SHA256SUMS
