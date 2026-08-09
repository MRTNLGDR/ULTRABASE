[CmdletBinding()]
param(
    [switch]$SemNavegador,
    [switch]$SemPull,
    [switch]$Reinstalar,
    [switch]$Parar
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$BootstrapScript = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$RuntimeDir = Split-Path -Parent $BootstrapScript
$UltrabaseDir = [System.IO.Path]::GetFullPath((Join-Path $RuntimeDir '..'))
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $UltrabaseDir '..'))
$DockerDir = Join-Path $RepoRoot 'docker'
$EnvFile = Join-Path $DockerDir '.env'
$EnvTemplate = Join-Path $DockerDir '.env.example'
$GeneratorScript = Join-Path $RuntimeDir 'generate-ultrabase-env.mjs'
$RuntimeScript = Join-Path $RuntimeDir 'Ultrabase-Runtime.ps1'
$CoreScript = Join-Path $UltrabaseDir 'scripts\ultrabase.ps1'
$DockerDesktopCandidates = @(
    (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe' }),
    (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Magenta
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture,
        [switch]$AllowFailure
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    if (-not $Capture) {
        $output | ForEach-Object { Write-Host $_ }
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $details = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) { $details = 'sem detalhes adicionais' }
        throw "Comando falhou ($exitCode): $FilePath $($Arguments -join ' ')`n$details"
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Get-CommandPath([string[]]$Names) {
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

function Assert-RequiredFiles {
    foreach ($file in @($EnvTemplate, $GeneratorScript, $RuntimeScript, $CoreScript, (Join-Path $DockerDir 'docker-compose.yml'), (Join-Path $DockerDir 'docker-compose.ultrabase-local.yml'))) {
        if (-not (Test-Path -LiteralPath $file)) { throw "Arquivo obrigatorio ausente: $file" }
    }
}

function Test-DockerDaemon {
    $docker = Get-CommandPath @('docker.exe', 'docker')
    if (-not $docker) { return $false }
    return ((Invoke-Native -FilePath $docker -Arguments @('info') -Capture -AllowFailure).ExitCode -eq 0)
}

function Ensure-DockerReady {
    $docker = Get-CommandPath @('docker.exe', 'docker')
    if (-not $docker) { throw 'Docker CLI nao encontrado. Instale o Docker Desktop oficial e execute RUN.bat novamente.' }
    if (Test-DockerDaemon) {
        Invoke-Native -FilePath $docker -Arguments @('compose', 'version') -Capture | Out-Null
        return $docker
    }

    $desktop = $DockerDesktopCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $desktop) { throw 'Docker Desktop esta instalado, mas o daemon nao responde e o executavel nao foi localizado.' }

    Write-Step 'Iniciando Docker Desktop'
    Start-Process -FilePath $desktop -WindowStyle Hidden
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        Start-Sleep -Seconds 2
        if (Test-DockerDaemon) {
            Invoke-Native -FilePath $docker -Arguments @('compose', 'version') -Capture | Out-Null
            return $docker
        }
    }
    throw 'Docker Desktop nao ficou pronto. Abra o Docker Desktop, corrija o erro exibido por ele e execute RUN.bat novamente.'
}

function Get-GitPath {
    return Get-CommandPath @('git.exe', 'git')
}

function Assert-SecretsIgnored {
    $git = Get-GitPath
    if (-not $git -or -not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) { return }

    $tracked = Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'ls-files', '--error-unmatch', 'docker/.env') -Capture -AllowFailure
    if ($tracked.ExitCode -eq 0) { throw 'FALHA DE SEGURANCA: docker/.env esta versionado. Remova-o do Git antes de continuar.' }

    $ignored = Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'check-ignore', '--no-index', '-q', 'docker/.env') -Capture -AllowFailure
    if ($ignored.ExitCode -ne 0) { throw 'FALHA DE SEGURANCA: docker/.env nao esta protegido pelo .gitignore.' }
}

function Invoke-SafeGitUpdate {
    if ($SemPull -or -not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) { return }
    $git = Get-GitPath
    if (-not $git) {
        Write-Warning 'Git nao encontrado; o runtime sera iniciado sem atualizar o codigo.'
        return
    }

    $origin = Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'remote', 'get-url', 'origin') -Capture -AllowFailure
    if ($origin.ExitCode -ne 0) {
        Write-Warning 'Remote origin ausente; o runtime sera iniciado sem git pull.'
        return
    }

    Write-Step 'Atualizando o repositorio sem apagar alteracoes locais'
    $dirty = Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'status', '--porcelain') -Capture
    $stashCreated = ($dirty.Output.Count -gt 0)
    $stashMessage = "ultrabase-run-$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    if ($stashCreated) {
        Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'stash', 'push', '--include-untracked', '-m', $stashMessage) | Out-Null
    }

    $updateError = $null
    try {
        Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'fetch', '--prune', 'origin') | Out-Null
        Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'pull', '--ff-only') | Out-Null
    } catch {
        $updateError = $_
    } finally {
        if ($stashCreated) {
            $restore = Invoke-Native -FilePath $git -Arguments @('-C', $RepoRoot, 'stash', 'pop') -Capture -AllowFailure
            if ($restore.ExitCode -ne 0) {
                throw "O Git atualizou, mas nao conseguiu reaplicar automaticamente suas alteracoes locais. Elas continuam protegidas no stash.`n$($restore.Output -join [Environment]::NewLine)"
            }
        }
    }
    if ($updateError) { throw $updateError }
}

function Get-NodeCommand {
    $node = Get-CommandPath @('node.exe', 'node')
    if ($node) {
        $version = Invoke-Native -FilePath $node -Arguments @('-p', 'Number(process.versions.node.split(".")[0])') -Capture -AllowFailure
        $major = 0
        $versionText = [string]($version.Output | Select-Object -First 1)
        if ($version.ExitCode -eq 0 -and [int]::TryParse($versionText, [ref]$major) -and $major -ge 22) {
            return [pscustomobject]@{ Mode = 'local'; Executable = $node }
        }
    }

    $docker = Ensure-DockerReady
    $image = Invoke-Native -FilePath $docker -Arguments @('image', 'inspect', 'node:22-alpine') -Capture -AllowFailure
    if ($image.ExitCode -ne 0) {
        Write-Step 'Baixando o Node 22 oficial para gerar a configuracao local'
        Invoke-Native -FilePath $docker -Arguments @('pull', 'node:22-alpine') | Out-Null
    }
    return [pscustomobject]@{ Mode = 'docker'; Executable = $docker }
}

function Convert-ContainerArgument([string]$Argument) {
    $repoPrefix = $RepoRoot.TrimEnd('\') + '\'
    if ($Argument.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '/workspace/' + $Argument.Substring($repoPrefix.Length).Replace('\', '/')
    }
    return $Argument
}

function Invoke-NodeScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$Capture
    )
    $runner = Get-NodeCommand
    if ($runner.Mode -eq 'local') {
        return Invoke-Native -FilePath $runner.Executable -Arguments (@($ScriptPath) + $Arguments) -AllowFailure:$AllowFailure -Capture:$Capture
    }

    $repoPrefix = $RepoRoot.TrimEnd('\') + '\'
    if (-not $ScriptPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Script Node fora do repositorio: $ScriptPath" }
    $relativeScript = $ScriptPath.Substring($repoPrefix.Length).Replace('\', '/')
    $translated = @($Arguments | ForEach-Object { Convert-ContainerArgument $_ })
    $dockerArguments = @('run', '--rm', '-v', "${RepoRoot}:/workspace", '-w', '/workspace', 'node:22-alpine', 'node', "/workspace/$relativeScript") + $translated
    return Invoke-Native -FilePath $runner.Executable -Arguments $dockerArguments -AllowFailure:$AllowFailure -Capture:$Capture
}

function Test-DatabaseInitialized {
    $pgVersion = Join-Path $DockerDir 'volumes\db\data\PG_VERSION'
    if (Test-Path -LiteralPath $pgVersion) { return $true }
    $dataDir = Split-Path -Parent $pgVersion
    if (-not (Test-Path -LiteralPath $dataDir)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Protect-EnvironmentFile {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return }
    try {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        foreach ($identity in @($currentUser, $system, $administrators)) {
            [void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $rights, $allow)))
        }
        Set-Acl -LiteralPath $EnvFile -AclObject $acl
    } catch {
        Write-Warning "Nao foi possivel restringir a ACL de docker/.env: $($_.Exception.Message)"
    }
}

function Ensure-SecureEnvironment {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        if (Test-DatabaseInitialized) {
            throw 'O banco existente perdeu docker/.env. O instalador recusou gerar novas chaves porque isso quebraria as credenciais do banco. Restaure o .env original do cofre/backup.'
        }
        Write-Step 'Gerando senhas, JWTs, JWKS ES256 e chaves opacas reais'
        Invoke-NodeScript -ScriptPath $GeneratorScript -Arguments @('--template', $EnvTemplate, '--env', $EnvFile, '--force') | Out-Null
    } else {
        $validation = Invoke-NodeScript -ScriptPath $GeneratorScript -Arguments @('--env', $EnvFile, '--check') -Capture -AllowFailure
        if ($validation.ExitCode -ne 0) {
            if (Test-DatabaseInitialized) {
                throw "docker/.env existe, mas falhou na validacao. Como o banco ja contem dados, o instalador nao rotacionou credenciais automaticamente.`n$($validation.Output -join [Environment]::NewLine)"
            }
            Write-Step 'Substituindo configuracao inicial insegura antes da criacao do banco'
            Invoke-NodeScript -ScriptPath $GeneratorScript -Arguments @('--template', $EnvTemplate, '--env', $EnvFile, '--force') | Out-Null
        }
    }

    Invoke-NodeScript -ScriptPath $GeneratorScript -Arguments @('--env', $EnvFile, '--check') | Out-Null
    Protect-EnvironmentFile
}

function Test-ComposeConfiguration([string]$Docker) {
    Write-Step 'Validando a composicao local antes de iniciar'
    Push-Location $DockerDir
    try { Invoke-Native -FilePath $Docker -Arguments @('compose', 'config', '--quiet') | Out-Null }
    finally { Pop-Location }
}

function Invoke-ComposeMaintenance([string]$Docker) {
    if (-not $Reinstalar) { return }
    Write-Step 'Atualizando imagens oficiais e reconstruindo o Studio Ultrabase sem apagar dados'
    Push-Location $DockerDir
    try {
        Invoke-Native -FilePath $Docker -Arguments @('compose', 'pull', '--ignore-buildable') | Out-Null
        Invoke-Native -FilePath $Docker -Arguments @('compose', 'build', '--pull', '--no-cache', 'studio') | Out-Null
    } finally { Pop-Location }
}

function Invoke-PowerShellScript([string]$Script, [string[]]$Arguments) {
    $powershell = Get-CommandPath @('powershell.exe', 'powershell')
    if (-not $powershell) { throw 'Windows PowerShell nao foi encontrado.' }
    return Invoke-Native -FilePath $powershell -Arguments (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments)
}

try {
    Set-Location $RepoRoot
    Write-Host ''
    Write-Host 'ULTRABASE - sua plataforma Postgres local' -ForegroundColor Magenta
    Assert-RequiredFiles

    if ($Parar) {
        Write-Step 'Parando os servicos sem apagar banco ou arquivos'
        Invoke-PowerShellScript -Script $CoreScript -Arguments @('-Action', 'stop') | Out-Null
        exit 0
    }

    Invoke-SafeGitUpdate
    Assert-RequiredFiles
    Assert-SecretsIgnored
    $docker = Ensure-DockerReady
    Ensure-SecureEnvironment
    Test-ComposeConfiguration -Docker $docker
    Invoke-ComposeMaintenance -Docker $docker

    Write-Step 'Instalando ou reparando o runtime automatico'
    Invoke-PowerShellScript -Script $RuntimeScript -Arguments @('-Action', 'install') | Out-Null

    Write-Step 'Executando validacao real dos servicos'
    Invoke-PowerShellScript -Script $RuntimeScript -Arguments @('-Action', 'verify') | Out-Null

    if (-not $SemNavegador) { Start-Process 'http://127.0.0.1:8000' }

    Write-Host ''
    Write-Host 'ULTRABASE PRONTO' -ForegroundColor Green
    Write-Host 'Painel e APIs: http://127.0.0.1:8000'
    Write-Host 'Segredos permanecem somente em docker/.env e nao sao enviados ao Git.'
    exit 0
} catch {
    Write-Host ''
    Write-Host 'ULTRABASE NAO FOI APROVADO' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
