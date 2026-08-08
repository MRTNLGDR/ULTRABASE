@echo off
title Ultrabase - Credenciais locais
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ultrabase.ps1" -Action credentials
pause
