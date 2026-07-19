TARI.Miner C29 v1.0.0
=====================

Community Tari Cuckaroo29 CUDA miner. No developer fee.

Linux quick start
-----------------
1. Open a terminal in this folder.
2. Make the files executable:
     chmod +x tari_c29_pool_miner tari_c29_solver start-c29.sh
3. Start mining:
     TARI_WALLET=YOUR_TARI_WALLET ./start-c29.sh

Optional settings
-----------------
TARI_POOL=taric29-ca.luckypool.io:3111 \
TARI_WORKER=RIG01 \
TARI_WALLET=YOUR_TARI_WALLET \
./start-c29.sh

Direct command
--------------
./tari_c29_pool_miner --pool taric29-ca.luckypool.io:3111 --wallet YOUR_TARI_WALLET --worker RIG01

Useful options
--------------
--device N
--pipeline N
--max-runtime-sec N
--help

If VRAM allocation fails, add --pipeline 1.

The standalone tari_c29_solver is for local testing. A correct run ends with
"verify failures: 0".
