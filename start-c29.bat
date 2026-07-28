@echo off
setlocal EnableExtensions

REM Optional permanent settings:
REM set "TARI_WALLET=YOUR_TARI_WALLET"
REM set "TARI_WORKER=RIG01"
REM set "TARI_DEVICES=0,2"
REM set "TARI_LOG_DIR=%~dp0logs"
REM set "TARI_LOGIN_SEPARATOR=/"

REM The work is done by start-c29.ps1. A batch file cannot run cleanup after
REM Ctrl+C, so workers it backgrounded outlived it and had to be ended by hand.
REM PowerShell stops every worker on interrupt, matching start-c29.sh.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-c29.ps1" %*
exit /b %ERRORLEVEL%
