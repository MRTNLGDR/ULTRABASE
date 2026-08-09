@echo off
REM ===========================================================================
REM  ULTRABASE - PONTO DE ENTRADA UNICO
REM
REM  Um clique neste arquivo:
REM     1. atualiza o Git sem apagar alteracoes locais
REM     2. valida ou gera segredos criptograficos fora do Git
REM     3. valida Docker Compose e dependencias
REM     4. sobe, verifica e monitora o Ultrabase
REM     5. abre o Studio em http://127.0.0.1:8000
REM
REM  Opcoes:
REM     RUN.bat /sem-navegador
REM     RUN.bat /sem-pull
REM     RUN.bat /reinstalar
REM     RUN.bat /parar
REM ===========================================================================
setlocal EnableExtensions
cd /d "%~dp0"
title Ultrabase

set "ARGS="
:parse
if "%~1"=="" goto pronto
if /i "%~1"=="/sem-navegador" set "ARGS=%ARGS% -SemNavegador" & shift & goto parse
if /i "%~1"=="/sem-pull"      set "ARGS=%ARGS% -SemPull"      & shift & goto parse
if /i "%~1"=="/reinstalar"    set "ARGS=%ARGS% -Reinstalar"   & shift & goto parse
if /i "%~1"=="/parar"         set "ARGS=%ARGS% -Parar"        & shift & goto parse
echo [AVISO] Opcao desconhecida: %~1
shift
goto parse

:pronto
set "BOOTSTRAP=%~dp0ultrabase\runtime\Ultrabase-Bootstrap.ps1"
set "SHARED_MOTOR=D:\AGENT_SYNC\motor-run.ps1"

if exist "%BOOTSTRAP%" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOTSTRAP%" %ARGS%
  set "RC=%ERRORLEVEL%"
  goto fim
)

REM Compatibilidade de emergencia para copias antigas/incompletas. O produto
REM normal nao depende deste arquivo externo.
if exist "%SHARED_MOTOR%" (
  echo [AVISO] Bootstrap interno ausente. Usando motor compartilhado de emergencia.
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SHARED_MOTOR%" -Projeto ULTRABASE %ARGS%
  set "RC=%ERRORLEVEL%"
  goto fim
)

echo [ERRO] Bootstrap interno nao encontrado em:
echo        %BOOTSTRAP%
echo [ERRO] Repare ou baixe novamente o repositorio ULTRABASE.
set "RC=9"

:fim
if not "%RC%"=="0" (
  echo.
  echo Ultrabase terminou com erro %RC%. Leia a causa acima.
  pause
)
endlocal & exit /b %RC%
