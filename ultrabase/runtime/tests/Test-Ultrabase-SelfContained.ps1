[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RuntimeDir = [System.IO.Path]::GetFullPath((Join-Path $TestDir '..'))
$UltrabaseDir = [System.IO.Path]::GetFullPath((Join-Path $RuntimeDir '..'))
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $UltrabaseDir '..'))
$Passed = 0
$Failed = 0

function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) {
        $script:Passed += 1
        Write-Host "PASS $Name" -ForegroundColor Green
    } else {
        $script:Failed += 1
        Write-Host "FAIL $Name" -ForegroundColor Red
    }
}

function Read-RepoFile([string]$RelativePath) {
    return Get-Content -LiteralPath (Join-Path $RepoRoot $RelativePath) -Raw
}

$run = Read-RepoFile 'RUN.bat'
$bootstrap = Read-RepoFile 'ultrabase/runtime/Ultrabase-Bootstrap.ps1'
$ignore = Read-RepoFile '.gitignore'
$generator = Read-RepoFile 'ultrabase/runtime/generate-ultrabase-env.mjs'

Assert-True ($run -match 'ultrabase\\runtime\\Ultrabase-Bootstrap\.ps1') 'RUN uses repository bootstrap'
Assert-True ($run -notmatch 'D:\\AGENT_SYNC') 'RUN has no external machine dependency'
Assert-True ($bootstrap -notmatch 'reset\s+--hard') 'bootstrap never hard-resets Git'
Assert-True ($bootstrap -match "stash', 'push', '--include-untracked") 'bootstrap preserves local work before pull'
Assert-True ($bootstrap -match 'generate-ultrabase-env\.mjs') 'bootstrap invokes cryptographic environment generator'
Assert-True ($bootstrap -match "'-Action', 'install'") 'bootstrap installs or repairs the real runtime'
Assert-True ($ignore -match '(?m)^docker/\.env$') 'docker/.env is explicitly ignored'
Assert-True ($ignore -notmatch '(?m)^!docker/\.env$') 'docker/.env cannot be re-included'
Assert-True ($ignore -match '(?m)^docker/backups/$') 'runtime backups are ignored'
Assert-True ($generator -match 'generateKeyPairSync') 'generator creates a real asymmetric signing key pair'
Assert-True ($generator -match 'timingSafeEqual') 'generator verifies legacy signatures cryptographically'
Assert-True ($generator -match 'cryptoVerify') 'generator verifies ES256 signatures cryptographically'
Assert-True ($generator -notmatch 'console\.log\([^\r\n]*(POSTGRES_PASSWORD|JWT_SECRET|SUPABASE_SECRET_KEY)') 'generator does not print named secrets'

Push-Location $RepoRoot
try {
    $ignoreResult = & git check-ignore --no-index docker/.env 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'Git actually ignores docker/.env'

    $node = Get-Command node -ErrorAction SilentlyContinue
    Assert-True ([bool]$node) 'Node.js is available for generator contract'
    if ($node) {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ultrabase-env-test-$PID"
        $tempEnv = Join-Path $tempRoot '.env'
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        try {
            $generateOutput = & $node.Source 'ultrabase/runtime/generate-ultrabase-env.mjs' '--env' $tempEnv '--template' 'docker/.env.example' '--json' 2>&1
            $generateExit = $LASTEXITCODE
            Assert-True ($generateExit -eq 0) 'generator creates a fresh environment'
            Assert-True (Test-Path -LiteralPath $tempEnv) 'generator writes the environment file'

            $checkOutput = & $node.Source 'ultrabase/runtime/generate-ultrabase-env.mjs' '--env' $tempEnv '--template' 'docker/.env.example' '--check' '--json' 2>&1
            $checkExit = $LASTEXITCODE
            Assert-True ($checkExit -eq 0) 'generated environment passes independent revalidation'

            if (Test-Path -LiteralPath $tempEnv) {
                $envContent = Get-Content -LiteralPath $tempEnv -Raw
                $postgresMatch = [regex]::Match($envContent, '(?m)^POSTGRES_PASSWORD=(.+)$')
                $combinedOutput = (($generateOutput + $checkOutput) | ForEach-Object { [string]$_ }) -join "`n"
                Assert-True ($postgresMatch.Success -and $combinedOutput -notlike "*$($postgresMatch.Groups[1].Value.Trim())*") 'generator output does not leak generated PostgreSQL password'
                Assert-True ($envContent -match '(?m)^FUNCTIONS_VERIFY_JWT=true$') 'generated profile enforces JWT on Functions'
                Assert-True ($envContent -match '(?m)^SUPABASE_PUBLIC_URL=http://127\.0\.0\.1:8000$') 'generated profile is loopback-only'
                Assert-True ($envContent -match '(?m)^COMPOSE_FILE=.*docker-compose\.ultrabase-local\.yml.*docker-compose\.logs\.yml$') 'generated profile enables local overlay and observability'
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    Pop-Location
}

Write-Host ''
Write-Host "Ultrabase self-contained contract: $Passed passed, $Failed failed"
if ($Failed -gt 0) {
    exit 1
}
