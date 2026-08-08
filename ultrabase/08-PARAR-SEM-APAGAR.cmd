@echo off
title Ultrabase - Parar sem apagar
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ultrabase.ps1" -Action stop
pause
