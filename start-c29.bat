@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
REM Optional permanent settings:
REM set "TARI_WALLET=YOUR_TARI_WALLET"
REM set "TARI_WORKER=RIG01"
REM set "TARI_DEVICES=0,2"
if not defined TARI_POOL set "TARI_POOL=taric29-ca.luckypool.io:3111"
if not defined TARI_WORKER set "TARI_WORKER=%COMPUTERNAME%"
if not defined TARI_DEVICES set "TARI_DEVICES=all"
if not defined TARI_NVIDIA_SMI set "TARI_NVIDIA_SMI=nvidia-smi"
set "TARI_MINER_ARGS=%*"

if not defined TARI_WALLET (
  echo TARI.Miner C29 - community miner with no developer fee
  echo Pool: %TARI_POOL%
  set /p "TARI_WALLET=Enter your Tari wallet address: "
)

if not defined TARI_WALLET (
  echo ERROR: A wallet address is required.
  exit /b 2
)

set "GPU_LIST=%TEMP%\tari-miner-gpus-%RANDOM%-%RANDOM%.csv"
call "%TARI_NVIDIA_SMI%" --query-gpu=index,compute_cap,name --format=csv,noheader,nounits > "%GPU_LIST%" 2>nul
if errorlevel 1 (
  del /q "%GPU_LIST%" >nul 2>nul
  echo ERROR: nvidia-smi could not enumerate NVIDIA GPUs.
  exit /b 3
)

set /a DETECTED=0, LAUNCHED=0, MISSING=0
for /f "usebackq tokens=1,2,* delims=," %%A in ("%GPU_LIST%") do call :launch_gpu "%%A" "%%B" "%%C"
del /q "%GPU_LIST%" >nul 2>nul

if %DETECTED% EQU 0 (
  echo ERROR: No NVIDIA GPUs were detected.
  exit /b 3
)

if %LAUNCHED% EQU 0 (
  echo ERROR: No supported GPUs matched TARI_DEVICES=%TARI_DEVICES%.
  exit /b 4
)

echo Started %LAUNCHED% miner worker(s) from %DETECTED% detected NVIDIA GPU(s).
if %MISSING% GTR 0 exit /b 5
exit /b 0

:launch_gpu
set /a DETECTED+=1
set "GPU_INDEX=%~1"
set "GPU_CAP=%~2"
set "GPU_NAME=%~3"
for /f "tokens=* delims= " %%G in ("%GPU_INDEX%") do set "GPU_INDEX=%%G"
for /f "tokens=* delims= " %%G in ("%GPU_CAP%") do set "GPU_CAP=%%G"
for /f "tokens=* delims= " %%G in ("%GPU_NAME%") do set "GPU_NAME=%%G"

if /I not "%TARI_DEVICES%"=="all" (
  set "GPU_SELECTED="
  for %%D in (%TARI_DEVICES:,= %) do if "%%D"=="%GPU_INDEX%" set "GPU_SELECTED=1"
  if not defined GPU_SELECTED exit /b 0
)
set "ARCH="
if "%GPU_CAP%"=="8.6" set "ARCH=sm_86"
if "%GPU_CAP%"=="8.9" set "ARCH=sm_89"
if "%GPU_CAP%"=="12.0" set "ARCH=sm_120"
if not defined ARCH (
  echo WARNING: Skipping GPU %GPU_INDEX% [%GPU_NAME%]: compute capability %GPU_CAP% is not supported.
  exit /b 0
)

set "BACKEND=%ROOT%bin\tari_c29_pool_miner_%ARCH%.exe"
if not exist "%BACKEND%" (
  echo ERROR: Missing %ARCH% backend for GPU %GPU_INDEX%: %BACKEND%
  set /a MISSING+=1
  exit /b 0
)

set "GPU_WORKER=%TARI_WORKER%-gpu%GPU_INDEX%"
echo GPU %GPU_INDEX% [%GPU_NAME%] compute %GPU_CAP% -^> %ARCH%, worker %GPU_WORKER%
if "%TARI_DRY_RUN%"=="1" (
  echo [DRY RUN] "%BACKEND%" %TARI_MINER_ARGS% --device %GPU_INDEX% --pool "%TARI_POOL%" --wallet "%TARI_WALLET%" --worker "%GPU_WORKER%"
) else (
  start "TARI.Miner GPU %GPU_INDEX%" /D "%ROOT%" "%BACKEND%" %TARI_MINER_ARGS% --device %GPU_INDEX% --pool "%TARI_POOL%" --wallet "%TARI_WALLET%" --worker "%GPU_WORKER%"
)
set /a LAUNCHED+=1
exit /b 0
