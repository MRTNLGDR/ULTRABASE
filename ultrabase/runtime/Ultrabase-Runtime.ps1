[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('install', 'ensure', 'status', 'verify', 'monitor', 'remove-autostart')]
    [string]$Action,

    [switch]$Json,
    [switch]$Quiet,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RuntimeScript = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$RuntimeSourceDir = Split-Path -Parent $RuntimeScript
$UltrabaseDir = [System.IO.Path]::GetFullPath((Join-Path $RuntimeSourceDir '..'))
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $UltrabaseDir '..'))
$CoreScript = Join-Path $UltrabaseDir 'scripts\ultrabase.ps1'
$DockerEnvFile = Join-Path $RepoRoot 'docker\.env'
$LocalRuntimeDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Ultrabase'
$ConnectionJsonFile = Join-Path $LocalRuntimeDir 'connection.json'
$ConnectionEnvFile = Join-Path $LocalRuntimeDir 'connection.env'
$StatusFile = Join-Path $LocalRuntimeDir 'runtime-status.json'
$LogFile = Join-Path $LocalRuntimeDir 'runtime.log'
$PreviousLogFile = Join-Path $LocalRuntimeDir 'runtime.previous.log'
$PauseFile = Join-Path $LocalRuntimeDir 'runtime.paused'
$MonitorPidFile = Join-Path $LocalRuntimeDir 'monitor.pid'
$StartupFolder = [Environment]::GetFolderPath('Startup')
$StartupLink = Join-Path $StartupFolder 'Ultrabase Local Runtime.lnk'
$PowerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$BaseUrl = 'http://127.0.0.1:8000'

function Initialize-LocalRuntimeDirectory {
    New-Item -ItemType Directory -Force -Path $LocalRuntimeDir | Out-Null
}

function Write-RuntimeLog([string]$Message) {
    Initialize-LocalRuntimeDirectory
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 2MB) {
        if (Test-Path -LiteralPath $PreviousLogFile) {
            Remove-Item -LiteralPath $PreviousLogFile -Force
        }
        Move-Item -LiteralPath $LogFile -Destination $PreviousLogFile
    }
    $line = "$([DateTimeOffset]::Now.ToString('o')) $Message"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
    Initialize-LocalRuntimeDirectory
    $resolvedRuntime = [System.IO.Path]::GetFullPath($LocalRuntimeDir).TrimEnd('\') + '\'
    $resolvedTarget = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedTarget.StartsWith($resolvedRuntime, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Destino de runtime fora da pasta permitida: $resolvedTarget"
    }
    $temporary = "$resolvedTarget.$PID.tmp"
    $jsonText = $Value | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($temporary, $jsonText + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $resolvedTarget -Force
}

function Read-DockerEnvironment {
    if (-not (Test-Path -LiteralPath $DockerEnvFile)) {
        throw "Configuração local ausente: $DockerEnvFile"
    }
    $values = @{}
    Get-Content -LiteralPath $DockerEnvFile | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $values[$name] = $value
        }
    }
    return $values
}

function Write-PublicConnectionFiles {
    $cfg = Read-DockerEnvironment
    $publicUrl = $cfg['SUPABASE_PUBLIC_URL']
    $publishableKey = $cfg['SUPABASE_PUBLISHABLE_KEY']
    if ([string]::IsNullOrWhiteSpace($publicUrl) -or [string]::IsNullOrWhiteSpace($publishableKey)) {
        throw 'URL pública ou chave publicável não foi encontrada na configuração local.'
    }
    if ($publicUrl -ne $BaseUrl) {
        throw "O runtime local exige SUPABASE_PUBLIC_URL=$BaseUrl. Valor atual diferente."
    }

    $connection = [ordered]@{
        schema_version = 1
        name = 'Ultrabase Local Runtime'
        generated_at = [DateTimeOffset]::Now.ToString('o')
        network_scope = 'loopback_only'
        same_computer_only = $true
        ultrabase_home = $RepoRoot
        url = $publicUrl
        server_url_from_docker_container = 'http://host.docker.internal:8000'
        publishable_key = $publishableKey
        studio_url = "$publicUrl/project/default"
        health_url = "$publicUrl/auth/v1/health"
        endpoints = [ordered]@{
            auth = "$publicUrl/auth/v1"
            rest = "$publicUrl/rest/v1"
            graphql = "$publicUrl/graphql/v1"
            storage = "$publicUrl/storage/v1"
            realtime = "$publicUrl/realtime/v1"
            functions = "$publicUrl/functions/v1"
        }
        postgres = [ordered]@{
            session = [ordered]@{ host = '127.0.0.1'; port = 5432; use = 'trusted_persistent_backend_or_admin' }
            transaction = [ordered]@{ host = '127.0.0.1'; port = 6543; use = 'short_lived_trusted_worker'; prepared_statements = $false }
            credentials_included = $false
        }
        runtime = [ordered]@{
            controller = $RuntimeScript
            ensure_arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RuntimeScript, '-Action', 'ensure', '-Json')
            status_arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RuntimeScript, '-Action', 'status', '-Json')
            pause_command = (Join-Path $UltrabaseDir '08-PARAR-SEM-APAGAR.cmd')
            resume_command = (Join-Path $UltrabaseDir '01-INICIAR-ULTRABASE.cmd')
        }
        client_rules = [ordered]@{
            use_data_api = $true
            require_rls = $true
            client_safe_fields = @('url', 'publishable_key')
            administrative_credentials_included = $false
            never_write_database_volume_directly = $true
        }
    }
    Write-JsonAtomic -Path $ConnectionJsonFile -Value $connection

    $envLines = @(
        "SUPABASE_URL=$publicUrl"
        "SUPABASE_PUBLISHABLE_KEY=$publishableKey"
        "ULTRABASE_CONNECTION_FILE=$ConnectionJsonFile"
    )
    $temporaryEnv = "$ConnectionEnvFile.$PID.tmp"
    [System.IO.File]::WriteAllLines($temporaryEnv, $envLines, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryEnv -Destination $ConnectionEnvFile -Force

    return $connection
}

function Set-UserRuntimeVariables {
    $variables = [ordered]@{
        ULTRABASE_HOME = $RepoRoot
        ULTRABASE_URL = $BaseUrl
        ULTRABASE_CONNECTION_FILE = $ConnectionJsonFile
        ULTRABASE_ENV_FILE = $ConnectionEnvFile
    }
    foreach ($entry in $variables.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'User')
        Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
    }
}

function Test-DockerDaemon {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & docker info *> $null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    return ($exitCode -eq 0)
}

function Get-RuntimeHealth {
    $cfg = Read-DockerEnvironment
    $healthCode = 0
    $ready = $false
    try {
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri "$BaseUrl/auth/v1/health" -Headers @{ apikey = $cfg['SUPABASE_PUBLISHABLE_KEY'] }
        $healthCode = [int]$response.StatusCode
        $ready = ($healthCode -eq 200)
    } catch {
        $healthCode = 0
    }
    return [ordered]@{
        status = if (Test-Path -LiteralPath $PauseFile) { 'paused' } elseif ($ready) { 'ready' } else { 'unavailable' }
        ready = $ready
        paused = (Test-Path -LiteralPath $PauseFile)
        http = $healthCode
        docker = (Test-DockerDaemon)
        url = $BaseUrl
        connection_file = $ConnectionJsonFile
        checked_at = [DateTimeOffset]::Now.ToString('o')
    }
}

function Save-RuntimeHealth([object]$Health) {
    Write-JsonAtomic -Path $StatusFile -Value $Health
}

function Invoke-CoreAction([ValidateSet('start', 'verify')] [string]$CoreAction, [switch]$Silent) {
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CoreScript, '-Action', $CoreAction)
    if ($Silent) {
        & $PowerShellExe @arguments *> $null
    } else {
        & $PowerShellExe @arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Ação central do Ultrabase falhou: $CoreAction"
    }
}

function Ensure-UltrabaseReady([switch]$Resume, [switch]$Silent) {
    Write-PublicConnectionFiles | Out-Null
    if ((Test-Path -LiteralPath $PauseFile) -and -not $Resume) {
        $pausedHealth = Get-RuntimeHealth
        Save-RuntimeHealth -Health $pausedHealth
        return $pausedHealth
    }
    if ($Resume -and (Test-Path -LiteralPath $PauseFile)) {
        Remove-Item -LiteralPath $PauseFile -Force
    }

    $health = Get-RuntimeHealth
    if ($health.ready) {
        Save-RuntimeHealth -Health $health
        return $health
    }

    $mutex = [System.Threading.Mutex]::new($false, 'Local\UltrabaseRuntimeEnsure')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(4))
        if (-not $acquired) {
            throw 'Outra inicialização do Ultrabase não terminou em quatro minutos.'
        }
        $health = Get-RuntimeHealth
        if (-not $health.ready) {
            Write-RuntimeLog 'Serviço indisponível; iniciando stack local.'
            Invoke-CoreAction -CoreAction start -Silent:$Silent
        }
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $health = Get-RuntimeHealth
            if ($health.ready) {
                Save-RuntimeHealth -Health $health
                Write-RuntimeLog 'Runtime pronto.'
                return $health
            }
            Start-Sleep -Seconds 2
        }
        throw 'O Ultrabase foi iniciado, mas o endpoint de saúde não respondeu em 60 segundos.'
    } finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Install-StartupLink {
    if (-not (Test-Path -LiteralPath $StartupFolder)) {
        throw "Pasta de inicialização do Windows não encontrada: $StartupFolder"
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($StartupLink)
    $shortcut.TargetPath = $PowerShellExe
    $shortcut.Arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RuntimeScript`" -Action monitor -Quiet"
    $shortcut.WorkingDirectory = $RepoRoot
    $shortcut.Description = 'Inicia e recupera o Ultrabase local para todos os aplicativos.'
    $shortcut.Save()
}

function Get-MonitorProcess {
    if (-not (Test-Path -LiteralPath $MonitorPidFile)) {
        return $null
    }
    $pidText = (Get-Content -LiteralPath $MonitorPidFile -Raw).Trim()
    $monitorPid = 0
    if (-not [int]::TryParse($pidText, [ref]$monitorPid)) {
        return $null
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $monitorPid" -ErrorAction SilentlyContinue
    if (-not $process) {
        return $null
    }
    if ($process.CommandLine -notlike "*$RuntimeScript*" -or $process.CommandLine -notmatch '(?i)-Action\s+monitor') {
        return $null
    }
    return $process
}

function Start-RuntimeMonitor {
    if (Get-MonitorProcess) {
        return
    }
    $arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RuntimeScript`" -Action monitor -Quiet"
    Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        Start-Sleep -Milliseconds 250
        if (Get-MonitorProcess) {
            return
        }
    }
    throw 'O monitor do Ultrabase não confirmou a inicialização.'
}

function Stop-RuntimeMonitor {
    $process = Get-MonitorProcess
    if ($process) {
        Stop-Process -Id ([int]$process.ProcessId) -Force
    }
    if (Test-Path -LiteralPath $MonitorPidFile) {
        Remove-Item -LiteralPath $MonitorPidFile -Force
    }
}

function Write-UserResult([object]$Result) {
    if ($Json) {
        $Result | ConvertTo-Json -Depth 10
        return
    }
    if ($Quiet) {
        return
    }
    Write-Host ''
    Write-Host 'Ultrabase Local Runtime' -ForegroundColor Magenta
    Write-Host "Estado:             $($Result.status)"
    Write-Host "URL dos apps:        $BaseUrl"
    Write-Host "Configuração JSON:   $ConnectionJsonFile"
    Write-Host "Configuração .env:   $ConnectionEnvFile"
    Write-Host "Início automático:   $([bool](Test-Path -LiteralPath $StartupLink))"
    Write-Host "Monitor em execução: $([bool](Get-MonitorProcess))"
    if ($Result.ready) {
        Write-Host 'Pronto para os aplicativos escreverem pela API.' -ForegroundColor Green
    } elseif ($Result.paused) {
        Write-Host 'Pausado pelo usuário. Use 01-INICIAR-ULTRABASE.cmd para retomar.' -ForegroundColor Yellow
    } else {
        Write-Host 'Indisponível.' -ForegroundColor Red
    }
}

function Invoke-MonitorLoop {
    Initialize-LocalRuntimeDirectory
    $mutex = [System.Threading.Mutex]::new($false, 'Local\UltrabaseRuntimeMonitor')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) {
            return
        }
        [System.IO.File]::WriteAllText($MonitorPidFile, [string]$PID, [System.Text.UTF8Encoding]::new($false))
        Write-RuntimeLog "Monitor iniciado; PID $PID."
        Write-PublicConnectionFiles | Out-Null
        while ($true) {
            try {
                if (Test-Path -LiteralPath $PauseFile) {
                    $pausedHealth = Get-RuntimeHealth
                    Save-RuntimeHealth -Health $pausedHealth
                } else {
                    $health = Get-RuntimeHealth
                    if (-not $health.ready) {
                        Write-RuntimeLog 'Monitor detectou indisponibilidade; tentando recuperar.'
                        $health = Ensure-UltrabaseReady -Silent
                    } else {
                        Save-RuntimeHealth -Health $health
                    }
                }
            } catch {
                Write-RuntimeLog "Falha de monitoramento: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 60
        }
    } finally {
        if ((Test-Path -LiteralPath $MonitorPidFile) -and ((Get-Content -LiteralPath $MonitorPidFile -Raw).Trim() -eq [string]$PID)) {
            Remove-Item -LiteralPath $MonitorPidFile -Force
        }
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

try {
    switch ($Action) {
        'install' {
            Initialize-LocalRuntimeDirectory
            Write-PublicConnectionFiles | Out-Null
            Set-UserRuntimeVariables
            Install-StartupLink
            $health = Ensure-UltrabaseReady -Resume -Silent:$Quiet
            Start-RuntimeMonitor
            Write-RuntimeLog 'Início automático instalado para o usuário atual.'
            Write-UserResult -Result $health
        }
        'ensure' {
            $health = Ensure-UltrabaseReady -Resume:$Force -Silent:$Quiet
            Write-UserResult -Result $health
            if ($health.paused) { exit 2 }
        }
        'status' {
            Write-PublicConnectionFiles | Out-Null
            $health = Get-RuntimeHealth
            Save-RuntimeHealth -Health $health
            Write-UserResult -Result $health
            if (-not $health.ready) { exit 1 }
        }
        'verify' {
            Write-PublicConnectionFiles | Out-Null
            Set-UserRuntimeVariables
            $health = Ensure-UltrabaseReady -Resume -Silent:$Quiet
            Invoke-CoreAction -CoreAction verify -Silent:$Quiet
            $health = Get-RuntimeHealth
            Save-RuntimeHealth -Health $health
            Write-RuntimeLog 'Validação completa aprovada.'
            Write-UserResult -Result $health
        }
        'monitor' {
            Invoke-MonitorLoop
        }
        'remove-autostart' {
            Stop-RuntimeMonitor
            if (Test-Path -LiteralPath $StartupLink) {
                Remove-Item -LiteralPath $StartupLink -Force
            }
            $health = Get-RuntimeHealth
            Save-RuntimeHealth -Health $health
            Write-RuntimeLog 'Início automático removido; dados e serviços preservados.'
            Write-UserResult -Result $health
        }
    }
} catch {
    Write-RuntimeLog "Ação $Action falhou: $($_.Exception.Message)"
    if ($Json) {
        [ordered]@{
            status = 'error'
            ready = $false
            action = $Action
            message = $_.Exception.Message
            connection_file = $ConnectionJsonFile
            checked_at = [DateTimeOffset]::Now.ToString('o')
        } | ConvertTo-Json -Depth 6
    } elseif (-not $Quiet) {
        Write-Error $_.Exception.Message
    }
    exit 1
}
