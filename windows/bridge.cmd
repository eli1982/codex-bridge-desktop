@echo off
setlocal

rem Use Windows PowerShell modules for the bridge's Authenticode check.
set "PSModulePath=%USERPROFILE%\Documents\WindowsPowerShell\Modules;%ProgramFiles%\WindowsPowerShell\Modules;%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"

set "BRIDGE_SCRIPT=%~dp0bridge-control.ps1"
if not exist "%BRIDGE_SCRIPT%" (
  echo Bridge control script is missing: "%BRIDGE_SCRIPT%"
  exit /b 1
)

if "%~1"=="" (
  if not exist "%~dp0Codex Bridge.exe" (
    echo Bridge launcher is missing: "%~dp0Codex Bridge.exe"
    exit /b 1
  )
  start "" "%~dp0Codex Bridge.exe"
  exit /b 0
)

if not "%~2"=="" (
  echo Configure the project folder with the installer.
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BRIDGE_SCRIPT%" -Action "%~1"
exit /b %ERRORLEVEL%
