TARI.Miner C29 v1.0.0
=====================

Community Tari Cuckaroo29 CUDA miner. No developer fee.

Windows quick start
-------------------
1. Run start-c29.bat.
2. Paste your Tari wallet address when prompted.
3. Keep the miner window open.

The starter is already configured for:
  Pool: taric29-ca.luckypool.io:3111
  Worker: your Windows computer name

To save your settings, edit start-c29.bat and set TARI_WALLET, TARI_WORKER,
or TARI_POOL near the top.

Direct command
--------------
tari_c29_pool_miner.exe --pool taric29-ca.luckypool.io:3111 --wallet YOUR_TARI_WALLET --worker RIG01

Useful options
--------------
--device N
--pipeline N
--max-runtime-sec N
--help

If VRAM allocation fails, add --pipeline 1.

The standalone tari_c29_solver.exe is for local testing. A correct run ends
with "verify failures: 0".
