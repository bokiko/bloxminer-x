<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
  <img src="assets/logo-light.svg" alt="BloxMiner-X" width="420">
</picture>

**RandomX CPU miner for Monero (XMR) — 0 % dev fee, runs on any x86-64 Linux, HiveOS-ready**

<p>
  <a href="https://github.com/bokiko/bloxminer-x"><img src="https://img.shields.io/badge/GitHub-bloxminer--x-181717?style=for-the-badge&logo=github" alt="GitHub"></a>
  <a href="https://www.getmonero.org"><img src="https://img.shields.io/badge/Monero-XMR-FF6600?style=for-the-badge" alt="Monero"></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Version-1.0.3-blue?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/Based_on-XMRig_6.26.0-00599C?style=flat-square" alt="XMRig">
  <img src="https://img.shields.io/badge/Algorithm-RandomX-blue?style=flat-square" alt="RandomX">
  <img src="https://img.shields.io/badge/Platform-Linux_x86--64-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/HiveOS-Ready-green?style=flat-square" alt="HiveOS">
  <img src="https://img.shields.io/badge/License-GPL--3.0-green?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/Dev_fee-0%25-brightgreen?style=flat-square" alt="0% dev fee">
</p>

</div>

---

## Index

- [What it mines](#what-it-mines)
- [Installation](#installation)
  - [HiveOS Flight Sheet (Recommended)](#hiveos-flight-sheet-recommended)
  - [HiveOS Terminal Install](#hiveos-terminal-install)
  - [Updating](#updating)
- [Usage](#usage)
- [HiveOS stats](#hiveos-stats)
- [Configuration](#configuration)
  - [Extra config keys](#extra-config-keys)
- [Requirements](#requirements)
- [Switching back to Verus](#switching-back-to-verus)
- [Building from source](#building-from-source)
- [Tests](#tests)
- [License](#license)

---

## What it mines

BloxMiner-X mines **RandomX** — the proof-of-work of [Monero (XMR)](https://www.getmonero.org) and the rest of
the RandomX family (Wownero, ArQmA, Graft, Safex, YadaCoin).

| | |
|---|---|
| **XMR and the RandomX family** | `rx/0` (default, Monero), `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada` |
| **Fees** | **0 %.** Built from [XMRig](https://github.com/xmrig/xmrig) 6.26.0 with exactly one source change: `src/donate.h`'s `kDefaultDonateLevel` and `kMinimumDonateLevel` are set to 0 instead of XMRig's default 1 %. Everything else — the mining engine, the stratum client, RandomX itself — is unmodified upstream XMRig code. GPL-3.0, same license as XMRig; full credit for the mining engine belongs to the XMRig authors (Copyright (c) 2016-present XMRig, SChernykh and contributors) — see [License](#license) |
| **Other coins / algorithms** | Not supported. This package only runs the RandomX family above |

**Also see:** [BloxMiner](https://github.com/bokiko/bloxminer) is the companion 0 %-fee **VerusHash** (VRSC)
CPU miner, same HiveOS custom-miner packaging.

---

## Installation

### HiveOS Flight Sheet (Recommended)

1. **Create New Flight Sheet**
   - Coin: `XMR` (Monero), or any other RandomX-family coin
   - Wallet: Select your Monero (or other RandomX-coin) wallet
   - Pool: `Configure in miner`

2. **Add Miner**
   - Miner: `Custom`
   - Miner name: `bloxminer-x`
   - Installation URL:
     ```
     https://github.com/bokiko/bloxminer-x/releases/download/1.0.3/bloxminer-x-1.0.3.tar.gz
     ```
   - Hash algorithm: `randomx` (HiveOS's own name for Monero RandomX; `rx/0` is also accepted)
   - Wallet and worker template: `%WAL%.%WORKER_NAME%`
   - Pool URL: your pool, e.g. `stratum+tcp://pool.supportxmr.com:3333`
   - Pass: the pool password, e.g. `x`

3. **Apply Flight Sheet** to your rig

#### Flight Sheet Fields

| Field | Value | Notes |
|-------|-------|-------|
| Miner | `custom` | Required |
| Miner name | `bloxminer-x` | Must match exactly |
| Installation URL | `https://github.com/bokiko/bloxminer-x/releases/download/1.0.3/bloxminer-x-1.0.3.tar.gz` | HiveOS installs it once and reuses it |
| Hash algorithm | `randomx` | HiveOS's own name for Monero RandomX, same as what the flight-sheet dropdown writes; `rx/0` is also accepted (XMRig's own name for the same algo). Other RandomX-family coins: `randomx-arq` (or `rx/arq`), `randomx-grft` (or `rx/graft`), `randomx-sfx` (or `rx/sfx`) — HiveOS has no name for `rx/wow` or `rx/yada`, so those two must be typed exactly as shown. Case-insensitive, extra spaces are ignored |
| Wallet template | `%WAL%.%WORKER_NAME%` | Your wallet.worker |
| Pool URL | `stratum+tcp://host:port`, `stratum+ssl://host:port`, or plain `host:port` | Your pool (plain `host:port` defaults to `stratum+tcp://`) |
| Pass | `x` | The pool **password** — not a thread count (this differs from the Verus BloxMiner) |
| Extra config arguments | *(empty)* | Optional JSON members, see [Extra config keys](#extra-config-keys) |

### HiveOS Terminal Install

```bash
/hive/miners/custom/custom-get https://github.com/bokiko/bloxminer-x/releases/download/1.0.3/bloxminer-x-1.0.3.tar.gz
```

Then set the flight sheet as above. On a fresh HiveOS image, HiveOS installs its custom-miner support automatically
the first time a flight sheet uses a Custom miner.

### Updating

Change the version in the Installation URL (e.g. `1.0.2` → `1.0.3`) and apply the flight sheet.
HiveOS downloads the new package and restarts the miner. Your flight sheet fields stay the same.

---

## Usage

HiveOS runs BloxMiner-X for you. Useful commands on the rig:

```bash
miner                 # open the miner screen (Ctrl+A, D to leave) - XMRig's own console output
miner restart         # restart
tail -f /var/log/miner/bloxminer-x/bloxminer-x.log     # XMRig's own log file
```

XMRig's local API (read-only, `127.0.0.1:4069`, used by HiveOS stats):

```bash
curl -s http://127.0.0.1:4069/2/summary | jq .
curl -s http://127.0.0.1:4069/2/backends | jq .
```

---

## HiveOS stats

`h-stats.sh` reads XMRig's own local HTTP API (`/2/summary`, `/2/backends`) and reports to Hive:

- One row per **physical core** (SMT thread pairs summed) when XMRig's reported thread affinities are bound to
  real CPUs and that binding is independently confirmed from the process's own task list — otherwise one row
  per thread, with the package temperature (the core mapping is shown as "unbound" in that case).
- Real per-core or per-package CPU temperature and, when readable (root, RAPL present), CPU package power,
  via `bloxsense` (this package's own small sensor helper).
- Accepted/rejected share counts and miner uptime, as numbers.
- A row's hashrate is XMRig's own 10-second average for that thread; it drops to 0 within roughly 10–20
  seconds of hashing actually stopping, and is not a "completed work" timestamp.
- If XMRig's API cannot be reached, or the socket on the configured port belongs to a different process (not
  this package's own `xmrig`), stats report 0 rather than showing another miner's numbers.
- The whole `h-stats.sh` run shares one 3-second deadline. The hashrate total is always answered from a single,
  cheap `/2/summary` call first (Phase A); the richer per-core/per-thread breakdown (`/2/backends` plus
  `bloxsense`, Phase B) only replaces it when it finishes in time AND its own total agrees with Phase A's —
  so a slow poll under heavy load degrades to "total only, no per-core breakdown" rather than ever reporting a
  false 0 when XMRig is actually hashing.
- State changes (API unavailable, affinity mapping not verified, recovered) get one timestamped line each,
  never on stdout, in a separate file next to the miner log: `<CUSTOM_LOG_BASENAME>.stats.log` (bounded to its
  last ~200 lines past 1 MiB). They are never written into XMRig's own log file: XMRig's `FileLogWriter` opens
  that file with `O_CREAT|O_WRONLY` (no `O_APPEND`) and writes at its own tracked offset from the size at open
  time, so a second writer's appended lines get silently overwritten by XMRig's next write and never survive —
  confirmed on a live rig. (XMRig's own log can also show a run of NUL bytes where Hive's 20-minute log-size
  cron truncated the file out from under XMRig's offset; Hive's own "Miner log" view and its truncate command
  already strip that — it is a pre-existing property of running any miner under Hive's log rotation, not
  specific to this package.)

---

## Configuration

The flight sheet is turned into `/hive/miners/custom/bloxminer-x/config.json` every time the miner starts.
`h-config.sh` writes it with `jq`, so every flight-sheet and Extra-config value is escaped — nothing is ever
interpolated into a shell command:

```json
{
  "colors": true,
  "print-time": 60,
  "cpu": { "enabled": true, "huge-pages": true },
  "randomx": {},
  "donate-level": 0,
  "donate-over-proxy": 0,
  "autosave": false,
  "background": false,
  "syslog": false,
  "log-file": "/var/log/miner/bloxminer-x/bloxminer-x.log",
  "http": { "enabled": true, "host": "127.0.0.1", "port": 4069, "restricted": true, "access-token": null },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "pools": [ { "url": "stratum+tcp://host:port", "user": "WALLET.rig1", "pass": "x", "algo": "rx/0" } ]
}
```

Threads are XMRig's own cache-aware autoconfig; Extra config can steer them via `"cpu": {"max-threads-hint": N}`
or `"cpu": {"rx": [...]}` (XMRig's own keys, passed through as-is).

### Extra config keys

Extra config is merged into the top-level XMRig config (as a default that XMRig's own config format then
overrides where BloxMiner-X needs a fixed value — Extra config CAN still override generic defaults like
`"print-time"`). A few keys BloxMiner-X always controls itself are dropped (with a message in the miner log)
if present: `donate-level`, `donate-over-proxy`, `http`, `api`, `autosave`, `log-file`, `background`, `syslog`,
`opencl`, `cuda`, `cpu.enabled` and `cpu."huge-pages"`.

Two keys are handled specially:

| Key | Behaviour |
|-----|-----------|
| `"tls": true` | Force TLS on the pool connection (a `stratum+ssl://` URL already implies it) |
| `"1gb-pages": true` | Opt-in only. Only applied if every NUMA node currently reports at least 3 GiB free memory (checked at config-build time); otherwise dropped with a message. XMRig reserves the 1 GB pages itself at startup and falls back to 2 MB pages if that reservation fails. Also accepted nested as `"randomx": {"1gb-pages": true}` — both forms go through the same NUMA-memory gate, so there is no way to set it unchecked |

Anything else passes straight through, e.g. `"cpu": {"max-threads-hint": 50}` or `"cpu": {"rx": [0,1,2,3]}`
to steer XMRig's own thread autoconfiguration, or `"randomx": {"rdmsr": false}`.

**TLS (since 1.0.3):** XMRig is built with OpenSSL 3.5 LTS at its default security level 2. TLS 1.2 and 1.3
pools with modern certificates work (tested: `pool.supportxmr.com:443` on TLS 1.3, `monerohash.com:9999` and
`pool.xmr.pt:9000` on TLS 1.2-only). A pool whose certificate uses an RSA key under 2048 bits or a SHA-1
signature is refused during the handshake; BloxMiner-X does not lower OpenSSL's security level to allow it. Use
that pool's plain `stratum+tcp://` port, or a different pool.

**Limitation (since 1.0.0):** the pool list is always exactly the one flight-sheet pool; Extra config cannot add
a failover/backup pool via a `"pools"` array (any `"pools"` in Extra config is ignored) — the same limitation
as the Verus BloxMiner.

---

## Requirements

| Category | Requirement |
|----------|-------------|
| **OS** | Any x86-64 Linux, including HiveOS |
| **CPU** | x86-64 with AES-NI (RandomX needs AES acceleration). `h-run.sh` refuses to start otherwise |
| **Privileges** | Root (Hive runs the miner as root already; XMRig applies the MSR mod and huge pages as root on Linux) |

---

## Switching back to Verus

BloxMiner-X calls Hive's own `hugepages -rx` helper (when present) before XMRig starts, and XMRig itself
reserves 2 MB huge pages as root at startup either way. **Neither BloxMiner-X nor XMRig releases that
reservation when XMRig stops** — `vm.nr_hugepages` stays at whatever value it was raised to. There is no
ownership tracking or automatic restore in this package: switching a rig from BloxMiner-X back to
[BloxMiner](https://github.com/bokiko/bloxminer#installation) (or to any other miner) is a manual step.

After XMRig has stopped:

1. Check whether anything else on this rig intentionally relies on the current `vm.nr_hugepages` value before
   changing it — another process may be using those pages, or a previous manual setting may be worth keeping.
2. Restore the previous value. On a stock HiveOS image that is `128` (`/etc/sysctl.conf`):
   ```bash
   sudo sysctl -w vm.nr_hugepages=128
   ```
   or reboot the rig — huge-page reservations do not persist across a reboot unless something else re-applies
   them.
3. If Extra config had `"1gb-pages": true` enabled, XMRig's 1 GB page pool is separate from the 2 MB pool above
   and needs its own check/release — it is not touched by `vm.nr_hugepages` or by step 2.

---

## Building from source

```bash
build/build.sh [outdir]     # Ubuntu 22.04, run as root (a container or chroot) - see the script header
build/package.sh <outdir> [pkgdir]
```

`build/build.sh` clones XMRig at the pinned tag (`v6.26.0`, commit `b2ca72480c58d197e18c885d9fc1a0c8d517e60a`),
verifies the exact commit, applies [`build/donate0.patch`](build/donate0.patch) (the only source change), builds
static libuv, hwloc and OpenSSL (3.5 LTS) from sha256-pinned tarballs, and builds both `xmrig` and `bloxsense` as static
binaries (no dynamic library dependencies).

`build/package.sh` assembles two artefacts: the HiveOS package `bloxminer-x-<version>.tar.gz` (with a generated
`SOURCE.md`, the bundled licenses and `build.provenance`), and `bloxminer-x-<version>-src.tar.gz`, the GPL
"Corresponding Source" — a fresh, re-verified checkout of XMRig at the pinned commit with `donate0.patch`
already applied, plus the build scripts and bloxsense sources, so anyone can inspect or rebuild the modified
binaries without trusting this repo's binaries or re-deriving the patch themselves.

---

## Tests

```bash
tests/bloxsense/run_tests.sh   # blox_sys.cpp unit tests + a bloxsense --json CLI smoke test, each run once
                                # plain and once under ASan+UBSan (needs g++, jq)
tests/hive/test_hive_scripts.sh   # h-config.sh / h-stats.sh behaviour against fake sysfs/procfs/API fixtures
tests/hive/test_under_load.sh     # h-stats.sh under real CPU load, with a large fake /proc and with a real
                                   # xmrig --bench - proves the /proc scans stay fast under load, not just on
                                   # an idle box (needs nproc; the real-xmrig case needs ~/bxwork/out/xmrig)
tests/build/test_package_provenance.sh   # build/package.sh refuses to ship a helper source that changed
                                          # since build/build.sh recorded its sha256
```

No performance claims are made here; XMRig's own donation mechanism is documented in `src/donate.h` and this is
a straightforward config-level change (0 % instead of the upstream default of 1 %), not a different mining engine.

---

## License

GPL-3.0 — see [LICENSE](LICENSE). BloxMiner-X is built from [XMRig](https://github.com/xmrig/xmrig), which is
GPL-licensed; all credit for the mining engine belongs to the XMRig authors (Copyright (c) 2016-present XMRig,
SChernykh and contributors). This project only adds the 0 % patch, the `bloxsense` CPU sensor helper, and the
HiveOS integration scripts (`h-*.sh`). The release package also statically links libuv (MIT), hwloc
(BSD-3-Clause) and OpenSSL 3 (Apache-2.0) — see [LICENSES](LICENSES) and `build/SOURCE.md` in a built package
for the exact commit, patch, dependency versions and how to reproduce the build. The logo's wordmark is drawn
from the Inter typeface (SIL Open Font License 1.1).

---

## Acknowledgments

- [XMRig](https://github.com/xmrig/xmrig) — XMRig, SChernykh and contributors
- [Monero Project](https://www.getmonero.org) — RandomX and the Monero network
- [Inter](https://rsms.me/inter/) — typeface of the logo wordmark

---

<p align="center">
  <a href="https://github.com/bokiko/bloxminer-x">GitHub</a> •
  <a href="https://www.getmonero.org">Monero.org</a>
</p>

<p align="center">
  Made by <a href="https://github.com/bokiko">@bokiko</a>
</p>
