@echo off
title Ultrabase - Ativar logs e analytics
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ultrabase.ps1" -Action enable-logs
pause
