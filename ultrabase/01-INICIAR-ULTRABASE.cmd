@echo off
title Ultrabase - Iniciar
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ultrabase.ps1" -Action start
pause
