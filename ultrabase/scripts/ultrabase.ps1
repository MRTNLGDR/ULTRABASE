[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'open', 'credentials', 'verify', 'backup', 'logs', 'enable-logs', 'stop')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot '..\..'))
$DockerDir = Join-Path $RepoRoot 'docker'
$EnvFile = Join-Path $DockerDir '.env'
$DockerDesktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$CoreCompose = 'docker-compose.yml:docker-compose.ultrabase-local.yml'
$LogsCompose = "$CoreCompose`:docker-compose.logs.yml"
$LocalRuntimeDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Ultrabase'
$RuntimePauseFile = Join-Path $LocalRuntimeDir 'runtime.paused'

function Resume-UltrabaseRuntime {
    if (Test-Path -LiteralPath $RuntimePauseFile) {
        Remove-Item -LiteralPath $RuntimePauseFile -Force
    }
}

function Suspend-UltrabaseRuntime {
    New-Item -ItemType Directory -Force -Path $LocalRuntimeDir | Out-Null
    [DateTimeOffset]::Now.ToString('o') | Set-Content -LiteralPath $RuntimePauseFile -Encoding UTF8
}

function Read-UltraEnv {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        throw 'docker/.env não existe. A instalação local precisa ser preparada novamente.'
    }

    $values = @{}
    Get-Content -LiteralPath $EnvFile | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }
    return $values
}

function Set-UltraEnvValue([string]$Name, [string]$Value) {
    $content = Get-Content -LiteralPath $EnvFile
    $replacement = "$Name=$Value"
    $found = $false
    $updated = foreach ($line in $content) {
        if ($line -match "^$([regex]::Escape($Name))=") {
            $found = $true
            $replacement
        } else {
            $line
        }
    }
    if (-not $found) {
        $updated += $replacement
    }
    [System.IO.File]::WriteAllLines($EnvFile, $updated, [System.Text.UTF8Encoding]::new($false))
}

function Test-DockerDaemon {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & docker info *> $null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    return ($exitCode -eq 0)
}

function Ensure-Docker {
    if (Test-DockerDaemon) {
        return
    }

    if (-not (Test-Path -LiteralPath $DockerDesktop)) {
        throw 'Docker Desktop não foi encontrado.'
    }

    Write-Host 'Iniciando Docker Desktop...'
    Start-Process -FilePath $DockerDesktop -WindowStyle Hidden
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        Start-Sleep -Seconds 2
        if (Test-DockerDaemon) {
            return
        }
    }
    throw 'Docker Desktop não ficou pronto em dois minutos.'
}

function Invoke-Compose([string[]]$ComposeArgs) {
    Push-Location $DockerDir
    try {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $composeOutput = & docker compose @ComposeArgs 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        $composeOutput | ForEach-Object { Write-Host $_ }
        if ($exitCode -ne 0) {
            throw "Docker Compose falhou: $($ComposeArgs -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

function Start-Ultrabase {
    Resume-UltrabaseRuntime
    Ensure-Docker
    try {
        Invoke-Compose @('up', '-d', '--wait', '--pull', 'never')
    } catch {
        Write-Host 'Os serviços ainda estão inicializando. Repetindo os health checks...'
        Start-Sleep -Seconds 8
        try {
            Invoke-Compose @('up', '-d', '--wait', '--pull', 'never')
        } catch {
            Write-Host 'Há imagens ausentes. Tentando completar o download oficial...'
            Invoke-Compose @('pull')
            Invoke-Compose @('up', '-d', '--wait')
        }
    }
    Write-Host ''
    Write-Host 'Ultrabase está pronto em http://127.0.0.1:8000' -ForegroundColor Green
}

function Show-Credentials {
    $cfg = Read-UltraEnv
    Write-Host ''
    Write-Host 'PAINEL NO-CODE' -ForegroundColor Cyan
    Write-Host "URL:     $($cfg['SUPABASE_PUBLIC_URL'])"
    Write-Host "E-mail:  $($cfg['DASHBOARD_USERNAME'])"
    Write-Host "Senha:   $($cfg['DASHBOARD_PASSWORD'])"
    Write-Host 'Acesso automático local: ATIVO (não pede login em 127.0.0.1)'
    Write-Host ''
    Write-Host 'CONEXÃO DOS APLICATIVOS' -ForegroundColor Cyan
    Write-Host "SUPABASE_URL=$($cfg['SUPABASE_PUBLIC_URL'])"
    Write-Host "SUPABASE_PUBLISHABLE_KEY=$($cfg['SUPABASE_PUBLISHABLE_KEY'])"
    Write-Host ''
    Write-Warning 'A chave secreta, a service role e a senha do PostgreSQL não são exibidas. Nunca coloque segredos em aplicativo cliente.'
}

function Verify-Ultrabase {
    Start-Ultrabase
    $cfg = Read-UltraEnv

    Push-Location $DockerDir
    try {
        $rows = docker compose ps --format '{{.Service}}|{{.Health}}|{{.Status}}'
        if ($LASTEXITCODE -ne 0) {
            throw 'Não foi possível consultar os serviços.'
        }
    } finally {
        Pop-Location
    }

    $bad = $rows | Where-Object { $_ -notmatch '\|healthy\|' }
    if ($bad) {
        throw "Serviços não saudáveis: $($bad -join ', ')"
    }

    $studioResponse = Invoke-WebRequest -UseBasicParsing -Uri "$($cfg['SUPABASE_PUBLIC_URL'])/"
    $studioCode = $studioResponse.StatusCode
    if ($studioCode -ne 200) {
        throw "Studio respondeu HTTP $studioCode"
    }
    if ($studioResponse.Headers['WWW-Authenticate']) {
        throw 'O painel local voltou a solicitar login.'
    }
    if ($studioResponse.Content -notmatch 'Ultrabase') {
        throw 'A marca Ultrabase não foi encontrada no painel.'
    }

    $logoResponse = Invoke-WebRequest -UseBasicParsing -Uri "$($cfg['SUPABASE_PUBLIC_URL'])/img/supabase-logo.svg"
    if ($logoResponse.Content -notmatch '#7C3AED' -or $logoResponse.Content -notmatch '#D946EF') {
        throw 'O logo roxo do Ultrabase não foi encontrado.'
    }

    $authCode = (Invoke-WebRequest -UseBasicParsing -Uri "$($cfg['SUPABASE_PUBLIC_URL'])/auth/v1/health" -Headers @{ apikey = $cfg['SUPABASE_PUBLISHABLE_KEY'] }).StatusCode
    $storageCode = (Invoke-WebRequest -UseBasicParsing -Uri "$($cfg['SUPABASE_PUBLIC_URL'])/storage/v1/status" -Headers @{ apikey = $cfg['SUPABASE_PUBLISHABLE_KEY']; Authorization = "Bearer $($cfg['ANON_KEY_ASYMMETRIC'])" }).StatusCode
    $restCode = (Invoke-WebRequest -UseBasicParsing -Uri "$($cfg['SUPABASE_PUBLIC_URL'])/rest/v1/" -Headers @{ apikey = $cfg['SUPABASE_SECRET_KEY']; Authorization = "Bearer $($cfg['SUPABASE_SECRET_KEY'])" }).StatusCode
    $functionText = Invoke-RestMethod -Uri "$($cfg['SUPABASE_PUBLIC_URL'])/functions/v1/hello" -Headers @{ apikey = $cfg['SUPABASE_PUBLISHABLE_KEY']; Authorization = "Bearer $($cfg['ANON_KEY_ASYMMETRIC'])" }
    if ($functionText -ne 'Hello from Edge Functions!') {
        throw 'A função local não retornou a resposta esperada.'
    }

    Write-Host ''
    Write-Host "Serviços saudáveis: $($rows.Count)" -ForegroundColor Green
    Write-Host "Studio: HTTP $studioCode"
    Write-Host "Auth: HTTP $authCode"
    Write-Host "REST: HTTP $restCode"
    Write-Host "Storage: HTTP $storageCode"
    Write-Host 'Realtime: healthy'
    Write-Host 'Edge Function: OK'
    Write-Host 'Identidade Ultrabase: roxo e acesso automático local OK'
}

function Backup-Ultrabase {
    Start-Ultrabase
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $hostBackupDir = Join-Path $DockerDir 'backups'
    $dbFile = "$stamp-database.dump"
    $rolesFile = "$stamp-roles.sql"
    $storageFile = Join-Path $hostBackupDir "$stamp-storage.zip"
    $manifestFile = Join-Path $hostBackupDir "$stamp-manifest.txt"

    New-Item -ItemType Directory -Force -Path $hostBackupDir | Out-Null
    docker exec supabase-db pg_dump -U postgres -d postgres --format=custom --file="/backups/$dbFile"
    if ($LASTEXITCODE -ne 0) { throw 'Falha no backup do banco.' }
    docker exec supabase-db pg_dumpall -U postgres --roles-only --file="/backups/$rolesFile"
    if ($LASTEXITCODE -ne 0) { throw 'Falha no backup das funções internas.' }

    $storageDir = Join-Path $DockerDir 'volumes\storage'
    if (Test-Path -LiteralPath $storageDir) {
        & tar.exe -a -cf $storageFile -C $storageDir .
        if ($LASTEXITCODE -ne 0) { throw 'Falha no backup do Storage.' }
    }

    $commit = git -C $RepoRoot rev-parse HEAD
    @(
        'Ultrabase backup'
        "Criado: $([DateTimeOffset]::Now.ToString('o'))"
        "Commit: $commit"
        "Banco: $dbFile"
        "Funções internas: $rolesFile"
        "Storage: $(Split-Path -Leaf $storageFile)"
        'Segredos não foram copiados. Guarde docker/.env separadamente em cofre criptografado.'
    ) | Set-Content -LiteralPath $manifestFile -Encoding UTF8

    Write-Host ''
    Write-Host "Backup concluído em $hostBackupDir" -ForegroundColor Green
}

function Enable-Logs {
    Ensure-Docker
    Set-UltraEnvValue -Name 'COMPOSE_FILE' -Value $LogsCompose
    try {
        Invoke-Compose @('pull', 'analytics', 'vector')
        Invoke-Compose @('up', '-d', '--wait')
        Write-Host 'Logs e Analytics locais foram habilitados.' -ForegroundColor Green
    } catch {
        Set-UltraEnvValue -Name 'COMPOSE_FILE' -Value $CoreCompose
        Invoke-Compose @('up', '-d', '--wait', '--pull', 'never')
        throw 'O CDN não entregou Logflare/Vector. A configuração voltou automaticamente aos 11 serviços centrais saudáveis.'
    }
}

switch ($Action) {
    'start' {
        Start-Ultrabase
    }
    'open' {
        Start-Ultrabase
        Start-Process 'http://127.0.0.1:8000'
        Write-Host 'Use 03-MOSTRAR-CREDENCIAIS.cmd para consultar o acesso local.'
    }
    'credentials' {
        Show-Credentials
    }
    'verify' {
        Verify-Ultrabase
    }
    'backup' {
        Backup-Ultrabase
    }
    'logs' {
        Ensure-Docker
        Invoke-Compose @('logs', '--tail', '200')
    }
    'enable-logs' {
        Enable-Logs
    }
    'stop' {
        Suspend-UltrabaseRuntime
        Ensure-Docker
        Invoke-Compose @('stop')
        Write-Host 'Ultrabase parado e recuperação automática pausada. Banco e arquivos foram preservados.' -ForegroundColor Yellow
        Write-Host 'Use 01-INICIAR-ULTRABASE.cmd para retomar.'
    }
}
