@echo off
title Ultrabase - Validar tudo
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ultrabase.ps1" -Action verify
pause
