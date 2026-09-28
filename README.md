# BloxMiner-X

BloxMiner-X is a 0%-developer-fee RandomX (Monero, XMR) CPU miner packaged as a HiveOS custom miner. It is
built from [XMRig](https://github.com/xmrig/xmrig) 6.26.0 with exactly one source change: `src/donate.h`'s
`kDefaultDonateLevel` and `kMinimumDonateLevel` are set to 0 instead of XMRig's default 1%. Everything else -
the mining engine, the stratum client, RandomX itself - is unmodified upstream XMRig code.

BloxMiner-X is licensed GPL-3.0, the same license as XMRig. All credit for the mining engine belongs to the
XMRig authors (Copyright (c) 2016-present XMRig, SChernykh and contributors); see `LICENSE` and `build/SOURCE.md`
in a built package for the exact commit, patch and how to reproduce the build. This project only adds the
0% patch, a small CPU sensor helper (`bloxsense`), and the HiveOS integration scripts (`h-*.sh`).

## What it reports

BloxMiner-X's `h-stats.sh` reads XMRig's own local HTTP API (`/2/summary`, `/2/backends`) and reports to Hive:

- One row per **physical core** (SMT thread pairs summed) when XMRig's reported thread affinities are bound to
  real CPUs and that binding is independently confirmed from the process's own task list - otherwise one row
  per thread, with the package temperature (the core mapping is shown as "unbound" in that case).
- Real per-core or per-package CPU temperature and, when readable (root, RAPL present), CPU package power,
  via `bloxsense`.
- Accepted/rejected share counts and miner uptime, as numbers.
- A row's hashrate is XMRig's own 10-second average for that thread; it drops to 0 within roughly 10-20
  seconds of hashing actually stopping, and is not a "completed work" timestamp.
- If XMRig's API cannot be reached, or the socket on the configured port belongs to a different process (not
  this package's own `xmrig`), stats report 0 rather than showing another miner's numbers.

## HiveOS flight sheet fields

| Field | Meaning |
|---|---|
| Pool URL | `stratum+tcp://host:port`, `stratum+ssl://host:port`, or plain `host:port` (defaults to `stratum+tcp://`) |
| Wallet / Template | XMRig pool `user`, e.g. `WALLET.worker` |
| **Pass** | the pool **password** (e.g. `x`) - not a thread count |
| Algorithm | one of the RandomX family: `rx/0` (default, Monero), `rx/wow`, `rx/arq`, `rx/graft`, `rx/sfx`, `rx/yada` |
| Extra config | optional JSON object members, merged into XMRig's config (see below) |

## Extra config keys

Extra config is merged into the top-level XMRig config. A few keys BloxMiner-X always controls itself are
dropped (with a message in the miner log) if present: `donate-level`, `donate-over-proxy`, `http`, `api`,
`autosave`, `log-file`, `background`, `syslog`, `opencl`, `cuda`, and `cpu.enabled`.

Two keys are handled specially:

- `"tls": true` - force TLS on the pool connection (a `stratum+ssl://` URL already implies it).
- `"1gb-pages": true` - opt-in only. Only applied if every NUMA node currently reports at least 3 GiB free
  memory (checked at config-build time); otherwise it is dropped with a message. XMRig reserves the 1 GB pages
  itself at startup and falls back to 2 MB pages if that reservation fails.

Anything else passes straight through, e.g. `"cpu": {"max-threads-hint": 50}` or `"cpu": {"rx": [0,1,2,3]}`
to steer XMRig's own thread autoconfiguration, or `"randomx": {"rdmsr": false}`.

## Requirements

- x86-64 CPU with AES-NI (RandomX needs AES acceleration). `h-run.sh` refuses to start otherwise.
- Root (Hive runs the miner as root already; XMRig applies the MSR mod and huge pages as root on Linux).

## Building from source

```
build/build.sh [outdir]     # Ubuntu 22.04, run as root (a container or chroot) - see the script header
build/package.sh <outdir> [pkgdir]
```

`build/build.sh` clones XMRig at the pinned tag, verifies the exact commit, applies `build/donate0.patch`
(the only source change), builds static libuv/hwloc/OpenSSL from sha256-pinned tarballs, and builds both
`xmrig` and `bloxsense` as static binaries (no dynamic library dependencies). `build/package.sh` assembles
the HiveOS package `bloxminer-x-<version>.tar.gz` with a generated `SOURCE.md` and the bundled licenses.

## Tests

```
tests/bloxsense/run_tests.sh   # blox_sys.cpp unit tests + a bloxsense --json CLI smoke test (needs g++, jq)
tests/hive/test_hive_scripts.sh   # h-config.sh / h-stats.sh behaviour against fake sysfs/procfs/API fixtures
```

No performance claims are made here; XMRig's own donation mechanism is documented in `src/donate.h` and
this is a straightforward config-level change (0% instead of the upstream default of 1%), not a different
mining engine.
