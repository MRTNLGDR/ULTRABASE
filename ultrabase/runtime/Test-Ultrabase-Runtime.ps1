[CmdletBinding()]
param(
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
$RuntimeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Controller = Join-Path $RuntimeDir 'Ultrabase-Runtime.ps1'
$LocalRuntimeDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Ultrabase'
$ConnectionJson = Join-Path $LocalRuntimeDir 'connection.json'
$ConnectionEnv = Join-Path $LocalRuntimeDir 'connection.env'
$StatusFile = Join-Path $LocalRuntimeDir 'runtime-status.json'
$MonitorPidFile = Join-Path $LocalRuntimeDir 'monitor.pid'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Ultrabase Local Runtime.lnk'
$checks = [System.Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
    $checks.Add($Message) | Out-Null
}

function Read-JsonFile([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path) "Arquivo existe: $Path"
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

$tokens = $null
$syntaxErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Controller, [ref]$tokens, [ref]$syntaxErrors) | Out-Null
Assert-True ($syntaxErrors.Count -eq 0) 'Controlador PowerShell sem erro de sintaxe'

$connection = Read-JsonFile -Path $ConnectionJson
Assert-True ($connection.schema_version -eq 1) 'Contrato de conexão na versão 1'
Assert-True ($connection.url -eq 'http://127.0.0.1:8000') 'URL de cliente presa ao loopback'
Assert-True ($connection.server_url_from_docker_container -eq 'http://host.docker.internal:8000') 'URL de backend em container declarada'
Assert-True ($connection.publishable_key -match '^sb_publishable_') 'Chave publicável moderna presente'
Assert-True ($connection.network_scope -eq 'loopback_only') 'Escopo local declarado'
Assert-True ($connection.client_rules.require_rls -eq $true) 'RLS obrigatória no contrato'
Assert-True ($connection.client_rules.administrative_credentials_included -eq $false) 'Credenciais administrativas ausentes no contrato'
Assert-True ($connection.postgres.credentials_included -eq $false) 'Senha PostgreSQL ausente no contrato'

$rawConnection = Get-Content -LiteralPath $ConnectionJson -Raw
$forbiddenNames = @('SUPABASE_SECRET_KEY', 'SERVICE_ROLE_KEY', 'POSTGRES_PASSWORD', 'JWT_SECRET', 'DASHBOARD_PASSWORD')
foreach ($forbidden in $forbiddenNames) {
    Assert-True ($rawConnection -notmatch [regex]::Escape($forbidden)) "Campo proibido ausente: $forbidden"
}

Assert-True (Test-Path -LiteralPath $ConnectionEnv) 'Arquivo .env público existe'
$envRows = Get-Content -LiteralPath $ConnectionEnv | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$envNames = @($envRows | ForEach-Object { ($_ -split '=', 2)[0] })
$allowedEnvNames = @('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'ULTRABASE_CONNECTION_FILE')
Assert-True ($envRows.Count -eq 3) 'Arquivo .env contém exatamente três variáveis públicas'
foreach ($name in $envNames) {
    Assert-True ($name -in $allowedEnvNames) "Variável pública permitida: $name"
}
foreach ($row in $envRows) {
    Assert-True (($row -split '=', 2)[1].Length -gt 0) 'Variável pública possui valor'
}

$status = Read-JsonFile -Path $StatusFile
Assert-True ($status.ready -eq $true) 'Runtime reporta estado pronto'
Assert-True ($status.http -eq 200) 'Endpoint de saúde responde HTTP 200'

Assert-True (Test-Path -LiteralPath $StartupLink) 'Atalho de início automático existe'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($StartupLink)
Assert-True ($shortcut.TargetPath -like '*powershell.exe') 'Atalho usa PowerShell do Windows'
Assert-True ($shortcut.Arguments -match 'Ultrabase-Runtime\.ps1') 'Atalho aponta para o controlador Ultrabase'
Assert-True ($shortcut.Arguments -match '(?i)-Action\s+monitor') 'Atalho inicia o monitor'

Assert-True (([Environment]::GetEnvironmentVariable('ULTRABASE_HOME', 'User')) -ne $null) 'ULTRABASE_HOME registrada para o usuário'
Assert-True (([Environment]::GetEnvironmentVariable('ULTRABASE_URL', 'User')) -eq 'http://127.0.0.1:8000') 'ULTRABASE_URL registrada para o usuário'
Assert-True (([Environment]::GetEnvironmentVariable('ULTRABASE_CONNECTION_FILE', 'User')) -eq $ConnectionJson) 'Caminho do contrato registrado para o usuário'
Assert-True (([Environment]::GetEnvironmentVariable('ULTRABASE_ENV_FILE', 'User')) -eq $ConnectionEnv) 'Caminho do .env registrado para o usuário'

Assert-True (Test-Path -LiteralPath $MonitorPidFile) 'PID do monitor existe'
$monitorPid = [int](Get-Content -LiteralPath $MonitorPidFile -Raw)
$monitor = Get-CimInstance Win32_Process -Filter "ProcessId = $monitorPid" -ErrorAction SilentlyContinue
Assert-True ([bool]$monitor) 'Monitor está em execução'
Assert-True ($monitor.CommandLine -match 'Ultrabase-Runtime\.ps1') 'Monitor executa o controlador correto'
Assert-True ($monitor.CommandLine -match '(?i)-Action\s+monitor') 'Processo ativo está no modo monitor'

$ensureOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Controller -Action ensure -Json
Assert-True ($LASTEXITCODE -eq 0) 'Ação ensure termina com sucesso'
$ensure = $ensureOutput | Out-String | ConvertFrom-Json
Assert-True ($ensure.ready -eq $true) 'Ação ensure confirma runtime pronto'
Assert-True ($ensure.http -eq 200) 'Ação ensure confirma endpoint HTTP 200'

if ($Full) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Controller -Action verify -Quiet
    Assert-True ($LASTEXITCODE -eq 0) 'Validação integral dos serviços aprovada'
}

[ordered]@{
    status = 'passed'
    checks = $checks.Count
    full_service_verification = [bool]$Full
    runtime_ready = $true
    http = 200
    autostart = $true
    monitor = $true
    connection_file = $ConnectionJson
    checked_at = [DateTimeOffset]::Now.ToString('o')
} | ConvertTo-Json -Depth 5
