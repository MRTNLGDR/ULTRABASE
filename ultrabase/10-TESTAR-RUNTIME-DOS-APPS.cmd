@echo off
chcp 65001 >nul
title Ultrabase - Testar runtime dos apps
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime\Ultrabase-Runtime.ps1" -Action verify
pause
