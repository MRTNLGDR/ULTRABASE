@echo off
chcp 65001 >nul
title Ultrabase - Remover inicio automatico
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime\Ultrabase-Runtime.ps1" -Action remove-autostart
pause
