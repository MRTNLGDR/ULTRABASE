@echo off
title Ultrabase - Abrir painel
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ultrabase.ps1" -Action open
pause
