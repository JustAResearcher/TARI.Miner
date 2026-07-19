@echo off
setlocal
if not defined TARI_POOL set "TARI_POOL=taric29-ca.luckypool.io:3111"
if not defined TARI_WORKER set "TARI_WORKER=%COMPUTERNAME%"

if not defined TARI_WALLET (
  echo TARI.Miner C29 - community miner with no developer fee
  echo Pool: %TARI_POOL%
  set /p "TARI_WALLET=Enter your Tari wallet address: "
)

if not defined TARI_WALLET (
  echo A wallet address is required.
  pause
  exit /b 2
)

"%~dp0tari_c29_pool_miner.exe" --pool "%TARI_POOL%" --wallet "%TARI_WALLET%" --worker "%TARI_WORKER%" %*
