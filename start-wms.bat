@echo off
chcp 65001 >nul
powershell -NoLogo -ExecutionPolicy Bypass -File "%~dp0start-wms.ps1"
if errorlevel 1 (
  echo.
  pause
)
