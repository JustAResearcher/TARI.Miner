@echo off
REM Build the Tari C29 wrapper self-test.
REM Requires an MSVC "x64 Native Tools Command Prompt" (so cl.exe is on PATH),
REM or run vcvars64.bat first. Falls back to g++/clang++ if cl is unavailable.
pushd "%~dp0"

where cl >nul 2>nul
if %errorlevel%==0 (
    echo Building with MSVC cl...
    cl /nologo /O2 /EHsc /std:c++17 tari_c29.cpp tari_c29_selftest.cpp /Fe:tari_c29_selftest.exe
    goto run
)

where g++ >nul 2>nul
if %errorlevel%==0 (
    echo Building with g++...
    g++ -O2 -std=c++17 tari_c29.cpp tari_c29_selftest.cpp -o tari_c29_selftest.exe
    goto run
)

where clang++ >nul 2>nul
if %errorlevel%==0 (
    echo Building with clang++...
    clang++ -O2 -std=c++17 tari_c29.cpp tari_c29_selftest.cpp -o tari_c29_selftest.exe
    goto run
)

echo No C++ compiler (cl/g++/clang++) found on PATH.
popd
exit /b 1

:run
if %errorlevel%==0 (
    echo.
    tari_c29_selftest.exe
)
set "BUILD_RC=%errorlevel%"
popd
exit /b %BUILD_RC%
