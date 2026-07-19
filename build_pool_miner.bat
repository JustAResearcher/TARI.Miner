@echo off
REM Build the LuckyPool-compatible Tari C29 pool miner.
REM Default arch sm_120 (RTX 5090 Blackwell). Override: build_pool_miner.bat sm_89
setlocal
set "ROOT=%~dp0"
set ARCH=%1
if "%ARCH%"=="" set ARCH=sm_120
set EXTRA_FLAGS=
if /I "%ARCH%"=="sm_120" set EXTRA_FLAGS=-DWARP_DST_ATOMICS_LATE=1 -DTARI_C29_DEFAULT_NTRIMS=48 -DSEEDB_REVERSE_LOOP=1 -DROUND0_DST_HASH_DYNAMIC_BITS=12 -DROUND0_DST_HASH_DYNAMIC_PROBES=4 -DROUND0_DST_HASH_FALLBACK_PLAIN=1 -DROUND0_DST_HASH_REPLAY_NORMAL_LOAD=1 -DROUND0_DST_HASH_REVERSE_INSERT=1 -DFUSE_FINAL_TAIL_CURRENT=1 -DFUSE_FINAL_TAIL_COUNT_NORMAL_LOAD=1 -DROUND23_TPB=960 -DROUND1_COUNT_NORMAL_LOAD=1 -DROUND23_COUNT_NORMAL_LOAD=1

if not defined NVCC set "NVCC=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin\nvcc.exe"
if not exist "%NVCC%" set "NVCC=nvcc"
set "CUCKAROO=%ROOT%third_party\cuckoo\src\cuckaroo"
set "CRYPTO=%ROOT%third_party\cuckoo\src\crypto"

echo Building tari_c29_pool_miner for %ARCH% ...
"%NVCC%" -O3 -std=c++17 -arch=%ARCH% --default-stream per-thread -DXBITS=7 -DIDXSHIFT=9 -DGRAPH_UNION_SKIP=1 -DSOLVER_PRELAUNCH_NEXT=1 -DRECOVERY_SMALL_OUTPUT=1 -DSEEDA_REHASH=1 %EXTRA_FLAGS% -maxrregcount=96 -Xptxas -flcm=cg ^
    -I"%ROOT%compat" ^
    -I"%CUCKAROO%" ^
    -I"%CRYPTO%" ^
    -Xcompiler "/wd4244 /wd4267 /wd4334 /wd4018" ^
    "%ROOT%tari_c29_pool_miner.cu" ^
    "%ROOT%tari_c29.cpp" ^
    "%CRYPTO%\blake2b-ref.c" ^
    ws2_32.lib ^
    -o "%ROOT%tari_c29_pool_miner.exe"

if errorlevel 1 (
    echo BUILD FAILED
    endlocal
    exit /b 1
) else (
    echo.
    echo BUILD OK -^> tari_c29_pool_miner.exe
    echo Try: tari_c29_pool_miner.exe --wallet YOUR_WALLET --worker %%COMPUTERNAME%%
)
endlocal
