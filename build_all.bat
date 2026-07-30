@echo off
setlocal EnableExtensions
pushd "%~dp0"

for %%A in (sm_86 sm_89 sm_120) do (
  call build_solver.bat %%A
  if errorlevel 1 goto failed
  call build_pool_miner.bat %%A
  if errorlevel 1 goto failed
  call build_solver.bat %%A reference
  if errorlevel 1 goto failed
)

echo.
echo All Windows GPU backends built successfully.
popd
exit /b 0

:failed
echo.
echo BUILD FAILED
popd
exit /b 1
