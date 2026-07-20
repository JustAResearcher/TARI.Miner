# TARI.Miner

TARI.Miner is an open-source NVIDIA CUDA miner for Tari (XTM) Cuckaroo29.
It connects to LuckyPool and has no developer fee, payout address, donation
schedule, or alternate mining connection.

## Download

Open the [latest release](https://github.com/JustAResearcher/TARI.Miner/releases/latest)
and download one file for your operating system:

- `TARI.Miner-v1.1.2-windows.zip`
- `TARI.Miner-v1.1.2-linux.tar.gz`
- `tari-miner-hiveos-1.1.2.tar.gz` for HiveOS

Each package contains all supported GPU backends. The starter detects every
NVIDIA GPU and selects the correct backend for each card:

- Compute capability 8.6: RTX 30 series
- Compute capability 8.9: RTX 40 series
- Compute capability 12.0: RTX 50 series

Mixed rigs are supported. Each GPU runs in its own process with a worker name
such as `RIG01-gpu0` or `RIG01-gpu1`. Pipeline depth is also selected inside
each process from that card's available VRAM.

The starter does not change GPU clocks, voltage, fans, or power limits.

## Windows

1. Extract `TARI.Miner-v1.1.2-windows.zip`.
2. Run `start-c29.bat`.
3. Paste your Tari wallet address when prompted.
4. Leave each GPU miner window open while mining.

The BAT file is preconfigured for `taric29-ca.luckypool.io:3111` and uses the
Windows computer name as the base worker name. To save settings, edit the
optional variables near the top of `start-c29.bat`.

To mine only on selected GPUs, set a comma-separated device list:

```bat
set "TARI_DEVICES=0,2"
start-c29.bat
```

Extra miner options are applied to every selected GPU:

```bat
start-c29.bat --pipeline 1
```

## Linux

Extract `TARI.Miner-v1.1.2-linux.tar.gz`, then run:

```bash
./start-c29.sh
```

The starter prompts for a wallet in an interactive terminal. Environment
variables can provide permanent settings:

```bash
TARI_POOL=taric29-ca.luckypool.io:3111 \
TARI_WORKER=RIG01 \
TARI_WALLET=YOUR_TARI_WALLET \
TARI_DEVICES=all \
./start-c29.sh
```

Use `TARI_DEVICES=0,2` to select specific GPUs. Press Ctrl+C to stop all GPU
workers started by the script.

## HiveOS

Create a Custom miner in the Flight Sheet with these values:

```text
Miner name: tari-miner-hiveos
Installation URL: https://github.com/JustAResearcher/TARI.Miner/releases/download/v1.1.2/tari-miner-hiveos-1.1.2.tar.gz
Hash algorithm: cuckaroo29
Wallet and worker template: %WAL%.%WORKER_NAME%
Pool URL: stratum+tcp://taric29-ca.luckypool.io:3111
Pass: x
```

The HiveOS launcher uses every supported GPU unless Extra config arguments
contains a selector such as `TARI_DEVICES=0,2`. Other extra arguments are
passed to each miner process, for example `--pipeline 1`. Per-GPU graph rates,
temperatures, fans, and share counters are reported to the HiveOS agent.

## Miner Options

Options placed after the starter command are passed to every selected GPU:

```text
--pool host:port        Pool endpoint
--wallet WALLET         Required Tari wallet address
--worker NAME           Worker name
--pass VALUE            Pool password; defaults to x
--pipeline N            Overlapped solver contexts; defaults automatically
--max-runtime-sec N     Stop after N seconds
--version               Print version and exit
```

The starter supplies `--device`, `--pool`, `--wallet`, and `--worker` after
user options so each GPU always receives its detected device index and unique
worker name. If automatic allocation does not fit in VRAM, retry with
`--pipeline 1`.

The pool connection is plain TCP. Do not use a sensitive password for
`--pass`; the default `x` is sufficient for LuckyPool.

## Test The Solver

The standalone solver checks GPU results with an independent CPU verifier.
Choose the backend matching the test GPU:

```bat
bin\tari_c29_solver_sm_89.exe --device 0 --count 320 --pipeline 2
```

```bash
bin/tari_c29_solver_sm_89 --device 0 --count 320 --pipeline 2
```

A correct run ends with `verify failures: 0`.

## Build From Source

The repository includes its required third-party source under
`third_party/cuckoo`.

Windows requires Visual Studio C++ tools and NVIDIA CUDA Toolkit 13.2. From an
x64 Native Tools Command Prompt:

```bat
build.bat
build_all.bat
```

Linux requires a C++ toolchain and an NVIDIA CUDA toolkit that supports all
three target architectures:

```bash
./build_all.sh
```

Individual backends can be built with `build_solver` or `build_pool_miner` and
one of `sm_86`, `sm_89`, or `sm_120`.

## License

TARI.Miner is GPL-3.0-or-later. Required upstream licenses and attribution are
included in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
`third_party/cuckoo/LICENSE.txt`.

This is independent community software and is not affiliated with or endorsed
by Tari or LuckyPool.
