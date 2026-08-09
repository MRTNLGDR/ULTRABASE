@echo off
chcp 65001 >nul
setlocal EnableExtensions
title Ultrabase - Migrations de aplicativo

set "APPROOT=%~1"
if not defined APPROOT (
  echo.
  echo Cole a pasta raiz do aplicativo que contem ultrabase.app.json
  set /p "APPROOT=App: "
)

if not defined APPROOT (
  echo Nenhuma pasta informada.
  pause
  exit /b 2
)

echo.
echo [1] Validar sem tocar no banco
echo [2] Planejar contra o banco atual
echo [3] Aplicar com backup obrigatorio
echo [4] Verificar estado aplicado
set /p "CHOICE=Escolha 1-4: "

if "%CHOICE%"=="1" set "ACTION=validate"
if "%CHOICE%"=="2" set "ACTION=plan"
if "%CHOICE%"=="3" set "ACTION=apply"
if "%CHOICE%"=="4" set "ACTION=verify"

if not defined ACTION (
  echo Opcao invalida.
  pause
  exit /b 2
)

echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime\Ultrabase-AppMigration.ps1" -Action "%ACTION%" -AppRoot "%APPROOT%"
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" (
  echo Operacao NAO concluida. Codigo: %EXITCODE%
  echo O erro acima precisa ser resolvido antes de considerar a migration pronta.
) else (
  echo Operacao concluida e validada para a acao escolhida.
)
pause
exit /b %EXITCODE%
