# TARI.Miner

TARI.Miner is a community-built, open-source NVIDIA CUDA miner for Tari (XTM)
Cuckaroo29. It includes a LuckyPool-compatible pool miner and a standalone GPU
solver for local testing.

**There is no developer fee.** The miner contains no payout address, donation
schedule, or alternate mining connection. It requires your wallet and mines
only to that wallet.

## Download

Download the package for your GPU from the
[latest release](https://github.com/JustAResearcher/TARI.Miner/releases/latest):

- `windows-sm86`: NVIDIA RTX 30 series
- `windows-sm89`: NVIDIA RTX 40 series
- `windows-sm120`: NVIDIA RTX 50 series
- `linux-sm86-ptx`: RTX 30 series, with PTX for newer-driver JIT
- `linux-sm120`: native RTX 50 series

## Windows

1. Download and extract the correct Windows ZIP.
2. Run `start-c29.bat`.
3. Paste your Tari wallet address when prompted.
4. Leave the miner window open while mining.

The included BAT file is already configured for
`taric29-ca.luckypool.io:3111` and uses the Windows computer name as the worker.
You can edit the variables at the top of the BAT file to make a wallet, worker,
or pool permanent.

## Linux

Extract the package, then run:

```bash
chmod +x tari_c29_pool_miner start-c29.sh
TARI_WALLET=YOUR_TARI_WALLET ./start-c29.sh
```

Optional variables:

```bash
TARI_POOL=taric29-ca.luckypool.io:3111 \
TARI_WORKER=RIG01 \
TARI_WALLET=YOUR_TARI_WALLET \
./start-c29.sh
```

## Direct Command

Windows:

```bat
tari_c29_pool_miner.exe --pool taric29-ca.luckypool.io:3111 --wallet YOUR_TARI_WALLET --worker RIG01
```

Linux:

```bash
./tari_c29_pool_miner --pool taric29-ca.luckypool.io:3111 --wallet YOUR_TARI_WALLET --worker RIG01
```

Useful options:

```text
--pool host:port        Pool endpoint
--wallet WALLET         Required Tari wallet address
--worker NAME           Worker name; defaults to host name
--pass VALUE            Pool password; defaults to x
--device N              CUDA device index; defaults to 0
--pipeline N            Overlapped solver contexts; defaults automatically
--max-runtime-sec N     Stop after N seconds
--version               Print version and exit
```

Run `tari_c29_pool_miner --help` for the full tuning list. If automatic
pipeline allocation does not fit in VRAM, retry with `--pipeline 1`.

The pool connection is plain TCP. Do not use a sensitive password for
`--pass`; the default `x` is sufficient for LuckyPool.

## Test The Solver

The standalone solver checks GPU results with an independent CPU verifier:

```text
tari_c29_solver --count 320 --pipeline 2
```

A correct run ends with `verify failures: 0`.

## Build From Source

The repository includes the required third-party source under
`third_party/cuckoo`.

Windows requirements:

- Visual Studio with Desktop development with C++
- NVIDIA CUDA Toolkit 13.2 for RTX 50 series, or a compatible toolkit for the
  selected architecture

From an x64 Native Tools Command Prompt:

```bat
build.bat
build_solver.bat sm_120
build_pool_miner.bat sm_120
```

Use `sm_89` for RTX 40 series or `sm_86` for RTX 30 series. Set `NVCC` to the
full CUDA compiler path when it is not installed in the default CUDA 13.2
location.

Linux:

```bash
./build_solver.sh sm_86
./build_pool_miner.sh sm_86
```

For RTX 50 series:

```bash
NVCC=/usr/local/cuda-13.2/bin/nvcc ./build_solver.sh sm_120
NVCC=/usr/local/cuda-13.2/bin/nvcc ./build_pool_miner.sh sm_120
```

Run `build.bat` on Windows to execute the offline CPU test suite. A passing run
reports `ALL PASSED (0 failures)`.

## License

TARI.Miner is GPL-3.0-or-later. Required upstream licenses and attribution are
included in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
`third_party/cuckoo/LICENSE.txt`.

This is independent community software and is not affiliated with or endorsed
by Tari or LuckyPool.
