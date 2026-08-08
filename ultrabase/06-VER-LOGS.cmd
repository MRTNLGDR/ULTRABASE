@echo off
title Ultrabase - Logs
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ultrabase.ps1" -Action logs
pause
