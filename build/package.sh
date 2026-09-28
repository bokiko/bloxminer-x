#!/usr/bin/env bash
# Assemble the HiveOS custom-miner release archive bloxminer-x-<version>.tar.gz (deterministic tar) + SHA256SUMS.
# Usage: build/package.sh <outdir built by build/build.sh> [outdir for the package]
# <outdir> must contain xmrig, bloxsense and build.provenance (written by build/build.sh); SOURCE.md is
# generated from build.provenance so the shipped notice always matches the binaries next to it.
set -euo pipefail
IN=${1:?path to the outdir built by build/build.sh}; IN=$(cd "$IN" && pwd)
OUT=${2:-$PWD}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PROV="$IN/build.provenance"
[[ -f $PROV ]] || { echo "missing $PROV (build with build/build.sh)"; exit 1; }
p() { sed -n "s/^$1=//p" "$PROV"; }

[[ $(p xmrig_sha256) == "$(sha256sum "$IN/xmrig" | cut -d' ' -f1)" ]] || { echo "$PROV does not describe $IN/xmrig (sha256 differs)"; exit 1; }
[[ $(p bloxsense_sha256) == "$(sha256sum "$IN/bloxsense" | cut -d' ' -f1)" ]] || { echo "$PROV does not describe $IN/bloxsense (sha256 differs)"; exit 1; }
[[ $(p patch_sha256) == "$(sha256sum "$HERE/donate0.patch" | cut -d' ' -f1)" ]] || { echo "binary was built from a different donate0.patch"; exit 1; }
VER=$(sed -n 's/^CUSTOM_VERSION=//p' "$ROOT/bloxminer-x/h-manifest.conf")

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D="$W/bloxminer-x"; mkdir -p "$D/LICENSES"
cp "$ROOT"/bloxminer-x/h-config.sh "$ROOT"/bloxminer-x/h-run.sh "$ROOT"/bloxminer-x/h-stats.sh "$ROOT"/bloxminer-x/h-manifest.conf "$D/"
cp "$IN/xmrig" "$D/xmrig"; cp "$IN/bloxsense" "$D/bloxsense"
cp "$ROOT/LICENSE" "$D/LICENSE"
cp "$ROOT"/LICENSES/LICENSE.libuv "$ROOT"/LICENSES/LICENSE.hwloc "$ROOT"/LICENSES/LICENSE.openssl "$D/LICENSES/"

cat > "$D/SOURCE.md" <<SRC
BloxMiner-X $VER - corresponding source (GPL-3.0)

BloxMiner-X is XMRig ($(p upstream)) at tag $(p upstream_tag), commit $(p upstream_commit),
with build/donate0.patch applied (the ONLY source change: src/donate.h kDefaultDonateLevel and
kMinimumDonateLevel, from 1 to 0 - a 0% developer donation instead of XMRig's default 1%), built by
build/build.sh: https://github.com/xmrig/xmrig/tree/$(p upstream_tag)

xmrig sha256            $(p xmrig_sha256)
bloxsense sha256        $(p bloxsense_sha256)
donate0.patch sha256    $(p patch_sha256)
compiler (xmrig)        $(p compiler.gcc)
compiler (bloxsense)    $(p compiler.gxx)
cmake                   $(p compiler.cmake)
SOURCE_DATE_EPOCH       $(p source_date_epoch)
build OS                $(p os)

Static dependencies (built from source by build/build.sh, sha256-pinned):
  libuv   $(p dep.libuv.version)    $(p dep.libuv.sha256)   $(p dep.libuv.url)
  hwloc   $(p dep.hwloc.version)    $(p dep.hwloc.sha256)   $(p dep.hwloc.url)
  OpenSSL $(p dep.openssl.version)  $(p dep.openssl.sha256) $(p dep.openssl.url)

To rebuild bit-for-bit: run build/build.sh as root in a stock Ubuntu 22.04 container/chroot; it clones
xmrig at the tag above, verifies the commit, applies donate0.patch, builds the three static dependencies
above from the same pinned, checksummed tarballs, and builds xmrig (cmake Release, BUILD_STATIC=ON, no
OpenCL/CUDA) and bloxsense (plain -O2) exactly as done here.

bloxsense/bloxsense.cpp is new (BloxMiner-X's own code); bloxsense/blox.h and bloxsense/blox_sys.cpp are
copied byte-identical from BloxMiner 2.1.0 (bokiko/bloxminer, GPL-3.0) - see that file's header comment.

Licenses: XMRig and bloxsense are GPL-3.0 (LICENSE). Statically linked dependencies: libuv (MIT),
hwloc (BSD-3-Clause), OpenSSL 3 (Apache-2.0) - see LICENSES/.
SRC

chmod 755 "$D" "$D"/*.sh "$D/xmrig" "$D/bloxsense"
chmod 644 "$D/h-manifest.conf" "$D/LICENSE" "$D/LICENSES"/* "$D/SOURCE.md"
TGZ="bloxminer-x-$VER.tar.gz"
tar --owner=0 --group=0 --numeric-owner --sort=name --mtime='2026-09-28 00:00:00Z' -C "$W" -cf - bloxminer-x | gzip -n -9 > "$OUT/$TGZ"
cd "$OUT"
{ sha256sum "$TGZ"; (cd "$W" && find bloxminer-x -type f | sort | xargs sha256sum); } > SHA256SUMS
cat SHA256SUMS
