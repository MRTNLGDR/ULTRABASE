[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('validate', 'plan', 'apply', 'verify')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$AppRoot,

    [switch]$AllowDestructive,
    [switch]$SkipBackup,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$RuntimeDir = Split-Path -Parent $ScriptPath
$UltrabaseDir = [System.IO.Path]::GetFullPath((Join-Path $RuntimeDir '..'))
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $UltrabaseDir '..'))
$RuntimeScript = Join-Path $RuntimeDir 'Ultrabase-Runtime.ps1'
$CoreScript = Join-Path $UltrabaseDir 'scripts\ultrabase.ps1'
$PlatformMigration = Join-Path $UltrabaseDir 'migrations\20260809022000_core_app_registry.sql'
$DockerBackupDir = Join-Path $RepoRoot 'docker\backups'
$ManifestName = 'ultrabase.app.json'
$ReservedSlugs = @('auth', 'storage', 'realtime', 'extensions', 'supabase_functions', 'vault', 'graphql', 'core')

function ConvertTo-SqlLiteral([AllowNull()][string]$Value) {
    if ($null -eq $Value) {
        return 'null'
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-ExistingDirectory([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Diretório não encontrado: $resolved"
    }
    return $resolved.TrimEnd('\', '/')
}

function Resolve-SafeChildPath([string]$Base, [string]$Relative) {
    if ([System.IO.Path]::IsPathRooted($Relative)) {
        throw "migrations_path deve ser relativo ao app: $Relative"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Base $Relative))
    $prefix = $Base.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "migrations_path sai da raiz do app: $Relative"
    }
    return $candidate
}

function Require-Command([string]$Name, [string]$Message) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name não foi encontrado. $Message"
    }
}

function Invoke-RuntimeEnsure {
    Require-Command 'docker' 'Instale/inicie o Docker Desktop antes de usar o runtime Ultrabase.'
    $raw = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $RuntimeScript -Action ensure -Json
    $exit = $LASTEXITCODE
    if ($exit -eq 2) {
        throw 'Ultrabase está pausado conscientemente. Retome pelo launcher oficial antes de aplicar migrations.'
    }
    if ($exit -ne 0) {
        throw "Ultrabase-Runtime.ps1 falhou com código $exit."
    }
    $health = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
    if (-not $health.ready) {
        throw 'Runtime Ultrabase não confirmou ready=true.'
    }
    return $health
}

function Invoke-DbQuery([string]$Sql) {
    $output = & docker exec supabase-db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Falha SQL no container supabase-db:`n$($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Invoke-DbFile([string]$Path) {
    $remote = "/tmp/ultrabase-$([guid]::NewGuid().ToString('N')).sql"
    try {
        & docker cp $Path "supabase-db:$remote" *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "docker cp falhou para $Path"
        }
        $output = & docker exec supabase-db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 --single-transaction -f $remote 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Migration falhou: $Path`n$($output -join [Environment]::NewLine)"
        }
        return @($output | ForEach-Object { [string]$_ })
    } finally {
        & docker exec supabase-db rm -f $remote *> $null
    }
}

function Test-CoreRegistry {
    $result = Invoke-DbQuery "select case when to_regclass('public.core_applications') is null then '0' else '1' end;"
    return ($result.Count -gt 0 -and $result[0].Trim() -eq '1')
}

function Invoke-PlatformRegistryMigration {
    if (-not (Test-Path -LiteralPath $PlatformMigration -PathType Leaf)) {
        throw "Migration de plataforma ausente: $PlatformMigration"
    }
    Invoke-DbFile -Path $PlatformMigration | Out-Null
    if (-not (Test-CoreRegistry)) {
        throw 'core_applications não existe após a migration de plataforma.'
    }
}

function Invoke-FullBackup {
    $before = @()
    if (Test-Path -LiteralPath $DockerBackupDir) {
        $before = @(Get-ChildItem -LiteralPath $DockerBackupDir -Filter '*-manifest.txt' -File | Select-Object -ExpandProperty FullName)
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $CoreScript -Action backup
    if ($LASTEXITCODE -ne 0) {
        throw 'Backup obrigatório falhou. Nenhuma migration será aplicada.'
    }

    $after = @(Get-ChildItem -LiteralPath $DockerBackupDir -Filter '*-manifest.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($after.Count -eq 0) {
        throw 'Backup terminou sem manifesto verificável.'
    }

    $manifest = $after[0].FullName
    if ($before -contains $manifest) {
        throw 'Nenhum novo manifesto de backup foi criado.'
    }
    return $manifest
}

function Test-InternalSchemaMutation([string]$Sql, [string]$FileName) {
    $internalMutation = '(?is)\b(?:alter\s+table|drop\s+(?:table|schema|function|procedure|view|type)|truncate\s+(?:table\s+)?|insert\s+into|update|delete\s+from|create\s+table)\s+(?:if\s+(?:not\s+)?exists\s+)?(?:auth|storage|realtime|extensions|supabase_functions|vault|graphql)\.'
    if ($Sql -match $internalMutation) {
        throw "$FileName tenta modificar diretamente um schema interno do Supabase. Policies em storage.objects são permitidas; DDL/DML interno não é."
    }
}

function Test-PublicObjectOwnership([string]$Sql, [string]$Prefix, [string]$FileName) {
    $createPattern = '(?is)\bcreate\s+(?:or\s+replace\s+)?(?:table|view|materialized\s+view|function|procedure|sequence)\s+(?:if\s+not\s+exists\s+)?public\.([a-zA-Z_][a-zA-Z0-9_]*)'
    foreach ($match in [regex]::Matches($Sql, $createPattern)) {
        $name = $match.Groups[1].Value.ToLowerInvariant()
        if (-not $name.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
            throw "$FileName cria public.$name fora do prefixo reservado $Prefix"
        }
    }

    $mutatePattern = '(?is)\b(?:alter\s+table|drop\s+(?:table|view|function|procedure|sequence)|truncate\s+(?:table\s+)?|insert\s+into|update|delete\s+from)\s+(?:if\s+exists\s+)?public\.([a-zA-Z_][a-zA-Z0-9_]*)'
    foreach ($match in [regex]::Matches($Sql, $mutatePattern)) {
        $name = $match.Groups[1].Value.ToLowerInvariant()
        if (-not $name.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
            throw "$FileName altera public.$name fora do prefixo reservado $Prefix"
        }
    }
}

function Get-MigrationDescriptor([System.IO.FileInfo]$File, [string]$Slug, [string]$Prefix) {
    $namePattern = "^[0-9]{14}_$([regex]::Escape($Slug))_.+\.sql$"
    if ($File.Name -notmatch $namePattern) {
        throw "Nome de migration inválido: $($File.Name). Use <timestamp>_${Slug}_<mudanca>.sql"
    }

    $sql = Get-Content -LiteralPath $File.FullName -Raw
    if ([string]::IsNullOrWhiteSpace($sql)) {
        throw "Migration vazia: $($File.Name)"
    }

    $secretPattern = '(?i)(SUPABASE_SECRET_KEY|SERVICE_ROLE_KEY|POSTGRES_PASSWORD|JWT_SECRET)\s*[:=]\s*[^\s<]+'
    if ($sql -match $secretPattern) {
        throw "$($File.Name) parece conter segredo/credencial. Migrations nunca podem transportar segredos."
    }

    Test-InternalSchemaMutation -Sql $sql -FileName $File.Name
    Test-PublicObjectOwnership -Sql $sql -Prefix $Prefix -FileName $File.Name

    $destructivePattern = '(?is)\b(?:drop\s+(?:table|view|function|procedure|type)|truncate\s+(?:table\s+)?|alter\s+table\b[^;]*\bdrop\s+(?:column|constraint)|delete\s+from\s+public\.)'
    $destructive = ($sql -match $destructivePattern)
    $rollbackPath = [System.IO.Path]::ChangeExtension($File.FullName, $null) + '.rollback.sql'
    $rollback = if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) { $rollbackPath } else { $null }

    if ($destructive -and -not $rollback) {
        throw "$($File.Name) contém operação destrutiva e não possui rollback irmão $([System.IO.Path]::GetFileName($rollbackPath))."
    }

    return [pscustomobject]@{
        name = $File.Name
        path = $File.FullName
        sha256 = Get-Sha256 -Path $File.FullName
        destructive = [bool]$destructive
        rollback_path = $rollback
        rollback_name = if ($rollback) { [System.IO.Path]::GetFileName($rollback) } else { $null }
    }
}

function Read-AppContract([string]$Root) {
    $manifestPath = Join-Path $Root $ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifesto obrigatório ausente: $manifestPath"
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        throw "JSON inválido em $manifestPath : $($_.Exception.Message)"
    }

    foreach ($required in @('schema_version', 'app_slug', 'display_name', 'table_prefix', 'migrations_path', 'database_owner')) {
        if ($null -eq $manifest.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace([string]$manifest.$required)) {
            throw "Campo obrigatório ausente em ultrabase.app.json: $required"
        }
    }

    if ([int]$manifest.schema_version -ne 1) {
        throw "schema_version não suportado: $($manifest.schema_version). Esperado: 1"
    }

    $slug = ([string]$manifest.app_slug).ToLowerInvariant()
    if ($slug -notmatch '^[a-z][a-z0-9_]{1,23}$') {
        throw "app_slug inválido: $slug"
    }
    if ($ReservedSlugs -contains $slug) {
        throw "app_slug reservado pelo Ultrabase/Supabase: $slug"
    }

    $prefix = ([string]$manifest.table_prefix).ToLowerInvariant()
    if ($prefix -ne "${slug}_") {
        throw "table_prefix deve ser exatamente ${slug}_"
    }

    $migrationDir = Resolve-SafeChildPath -Base $Root -Relative ([string]$manifest.migrations_path)
    if (-not (Test-Path -LiteralPath $migrationDir -PathType Container)) {
        throw "Pasta de migrations não existe: $migrationDir"
    }

    $buckets = @()
    if ($manifest.PSObject.Properties['buckets']) { $buckets = @($manifest.buckets) }
    foreach ($bucket in $buckets) {
        $bucketText = [string]$bucket
        if (-not $bucketText.StartsWith(($slug.Replace('_', '-') + '-'), [System.StringComparison]::Ordinal)) {
            throw "Bucket fora do namespace do app: $bucketText"
        }
    }

    $edgeFunctions = @()
    if ($manifest.PSObject.Properties['edge_functions']) { $edgeFunctions = @($manifest.edge_functions) }
    foreach ($functionName in $edgeFunctions) {
        $functionText = [string]$functionName
        if (-not $functionText.StartsWith(($slug.Replace('_', '-') + '-'), [System.StringComparison]::Ordinal)) {
            throw "Edge Function fora do namespace do app: $functionText"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $migrationDir -File -Filter '*.sql' |
        Where-Object { $_.Name -notlike '*.rollback.sql' } |
        Sort-Object Name)
    if ($files.Count -eq 0) {
        throw "Nenhuma migration encontrada em $migrationDir"
    }

    $migrations = @()
    foreach ($file in $files) {
        $migrations += Get-MigrationDescriptor -File $file -Slug $slug -Prefix $prefix
    }

    return [pscustomobject]@{
        root = $Root
        manifest_path = $manifestPath
        manifest_sha256 = Get-Sha256 -Path $manifestPath
        manifest = $manifest
        slug = $slug
        prefix = $prefix
        migration_dir = $migrationDir
        migrations = $migrations
        buckets = $buckets
        edge_functions = $edgeFunctions
    }
}

function Get-GitCommit([string]$Root) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $value = & git -C $Root rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$value).Trim()
}

function Get-SourceRepository([string]$Root, [object]$Manifest) {
    if ($Manifest.PSObject.Properties['source_repository'] -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.source_repository)) {
        return [string]$Manifest.source_repository
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $value = & git -C $Root remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$value).Trim()
}

function Get-AppliedMigrations([string]$Slug) {
    $rows = Invoke-DbQuery "select migration_name || E'\t' || migration_sha256 from public.core_app_migrations where app_slug=$(ConvertTo-SqlLiteral $Slug) order by migration_name;"
    $map = @{}
    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        $parts = $row -split "`t", 2
        if ($parts.Count -eq 2) { $map[$parts[0]] = $parts[1] }
    }
    return $map
}

function Get-PrefixObjectCount([string]$Prefix) {
    $prefixLiteral = ConvertTo-SqlLiteral ($Prefix + '%')
    $rows = Invoke-DbQuery "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S') and c.relname like $prefixLiteral;"
    return [int]$rows[0]
}

function Register-App([object]$Contract) {
    $m = $Contract.manifest
    $sourceRepo = Get-SourceRepository -Root $Contract.root -Manifest $m
    $bucketsJson = ($Contract.buckets | ConvertTo-Json -Compress)
    $edgeJson = ($Contract.edge_functions | ConvertTo-Json -Compress)
    $deps = @()
    if ($m.PSObject.Properties['shared_dependencies']) { $deps = @($m.shared_dependencies) }
    $depsJson = ($deps | ConvertTo-Json -Compress)

    $sql = @"
insert into public.core_applications (
  app_slug, display_name, table_prefix, schema_version, source_repository,
  manifest_sha256, migrations_path, buckets, edge_functions, shared_dependencies, status
) values (
  $(ConvertTo-SqlLiteral $Contract.slug),
  $(ConvertTo-SqlLiteral ([string]$m.display_name)),
  $(ConvertTo-SqlLiteral $Contract.prefix),
  1,
  $(ConvertTo-SqlLiteral $sourceRepo),
  $(ConvertTo-SqlLiteral $Contract.manifest_sha256),
  $(ConvertTo-SqlLiteral ([string]$m.migrations_path)),
  $(ConvertTo-SqlLiteral $bucketsJson)::jsonb,
  $(ConvertTo-SqlLiteral $edgeJson)::jsonb,
  $(ConvertTo-SqlLiteral $depsJson)::jsonb,
  'active'
)
on conflict (app_slug) do update set
  display_name = excluded.display_name,
  manifest_sha256 = excluded.manifest_sha256,
  migrations_path = excluded.migrations_path,
  buckets = excluded.buckets,
  edge_functions = excluded.edge_functions,
  shared_dependencies = excluded.shared_dependencies,
  source_repository = coalesce(excluded.source_repository, public.core_applications.source_repository),
  updated_at = now()
where public.core_applications.table_prefix = excluded.table_prefix;
"@
    Invoke-DbQuery $sql | Out-Null

    $registeredPrefix = Invoke-DbQuery "select table_prefix from public.core_applications where app_slug=$(ConvertTo-SqlLiteral $Contract.slug);"
    if ($registeredPrefix.Count -eq 0 -or $registeredPrefix[0] -ne $Contract.prefix) {
        throw "O app_slug $($Contract.slug) já está reservado com outro table_prefix."
    }
}

function New-MigrationRun([string]$Slug, [string]$RunAction, [int]$PendingCount, [AllowNull()][string]$BackupManifest) {
    $rows = Invoke-DbQuery @"
insert into public.core_app_migration_runs (app_slug, action, status, pending_count, backup_manifest)
values ($(ConvertTo-SqlLiteral $Slug), $(ConvertTo-SqlLiteral $RunAction), 'running', $PendingCount, $(ConvertTo-SqlLiteral $BackupManifest))
returning id::text;
"@
    if ($rows.Count -eq 0) { throw 'Não foi possível criar registro de execução de migration.' }
    return $rows[0].Trim()
}

function Complete-MigrationRun([string]$RunId, [string]$Status, [int]$AppliedCount, [AllowNull()][string]$ErrorMessage) {
    Invoke-DbQuery @"
update public.core_app_migration_runs
set status=$(ConvertTo-SqlLiteral $Status),
    applied_count=$AppliedCount,
    error_message=$(ConvertTo-SqlLiteral $ErrorMessage),
    finished_at=now()
where id=$(ConvertTo-SqlLiteral $RunId)::uuid;
"@ | Out-Null
}

function Record-Migration([object]$Contract, [object]$Migration, [AllowNull()][string]$Commit) {
    $metadata = [ordered]@{
        manifest_sha256 = $Contract.manifest_sha256
        source_root = $Contract.root
    } | ConvertTo-Json -Compress

    Invoke-DbQuery @"
insert into public.core_app_migrations (
  app_slug, migration_name, migration_sha256, destructive, rollback_name, ultrabase_commit, metadata
) values (
  $(ConvertTo-SqlLiteral $Contract.slug),
  $(ConvertTo-SqlLiteral $Migration.name),
  $(ConvertTo-SqlLiteral $Migration.sha256),
  $(if ($Migration.destructive) { 'true' } else { 'false' }),
  $(ConvertTo-SqlLiteral $Migration.rollback_name),
  $(ConvertTo-SqlLiteral $Commit),
  $(ConvertTo-SqlLiteral $metadata)::jsonb
);
"@ | Out-Null
}

function Compare-MigrationState([object]$Contract, [hashtable]$Applied) {
    $pending = @()
    $verified = @()
    foreach ($migration in $Contract.migrations) {
        if ($Applied.ContainsKey($migration.name)) {
            if ($Applied[$migration.name] -ne $migration.sha256) {
                throw "Migration já aplicada foi modificada: $($migration.name). Esperado $($Applied[$migration.name]); atual $($migration.sha256). Crie uma nova migration em vez de reescrever histórico."
            }
            $verified += $migration
        } else {
            $pending += $migration
        }
    }

    $missingFiles = @($Applied.Keys | Where-Object { $_ -notin @($Contract.migrations.name) })
    if ($missingFiles.Count -gt 0) {
        throw "Migrations aplicadas sumiram do repositório: $($missingFiles -join ', '). O histórico versionado não pode ser apagado."
    }

    return [pscustomobject]@{ pending = $pending; verified = $verified }
}

function Write-Result([object]$Result) {
    if ($Json) {
        $Result | ConvertTo-Json -Depth 12
        return
    }

    Write-Host ''
    Write-Host 'Ultrabase App Migration' -ForegroundColor Magenta
    Write-Host "Ação:             $($Result.action)"
    Write-Host "App:              $($Result.app_slug)"
    Write-Host "Manifesto:        $($Result.manifest)"
    Write-Host "Migrations:       $($Result.total_migrations)"
    Write-Host "Aplicadas:        $($Result.applied_migrations)"
    Write-Host "Pendentes:        $($Result.pending_migrations)"
    Write-Host "Registro core:    $($Result.platform_registry)"
    if ($Result.PSObject.Properties['backup_manifest'] -and $Result.backup_manifest) {
        Write-Host "Backup:           $($Result.backup_manifest)"
    }
    if ($Result.PSObject.Properties['status']) {
        Write-Host "Estado:           $($Result.status)" -ForegroundColor Green
    }
}

$appPath = Resolve-ExistingDirectory -Path $AppRoot
$contract = Read-AppContract -Root $appPath

if ($Action -eq 'validate') {
    Write-Result ([pscustomobject]@{
        action = $Action
        app_slug = $contract.slug
        manifest = $contract.manifest_path
        total_migrations = $contract.migrations.Count
        applied_migrations = 0
        pending_migrations = $contract.migrations.Count
        platform_registry = 'not_checked'
        status = 'valid'
    })
    exit 0
}

$runtime = Invoke-RuntimeEnsure
$registryExists = Test-CoreRegistry

if (-not $registryExists -and $Action -eq 'verify') {
    throw 'Registro core de apps ainda não está instalado. Execute Action=apply para a primeira aplicação governada.'
}

if (-not $registryExists -and $Action -eq 'plan') {
    $existingObjects = Get-PrefixObjectCount -Prefix $contract.prefix
    if ($existingObjects -gt 0) {
        throw "O namespace $($contract.prefix) já possui $existingObjects objeto(s) no banco, mas não existe ledger core. Pare e faça uma adoção/migração explícita; não é seguro fingir que migrations nunca foram aplicadas."
    }
    Write-Result ([pscustomobject]@{
        action = $Action
        app_slug = $contract.slug
        manifest = $contract.manifest_path
        total_migrations = $contract.migrations.Count
        applied_migrations = 0
        pending_migrations = $contract.migrations.Count
        platform_registry = 'pending_install'
        status = 'planned'
    })
    exit 0
}

$backupManifest = $null
if ($Action -eq 'apply' -and -not $registryExists) {
    $existingObjects = Get-PrefixObjectCount -Prefix $contract.prefix
    if ($existingObjects -gt 0) {
        throw "O namespace $($contract.prefix) já possui $existingObjects objeto(s) sem ledger core. A aplicação automática foi bloqueada para impedir sobreposição de schema."
    }
    if (-not $SkipBackup) {
        $backupManifest = Invoke-FullBackup
    }
    Invoke-PlatformRegistryMigration
    $registryExists = $true
}

Register-App -Contract $contract
$applied = Get-AppliedMigrations -Slug $contract.slug
$state = Compare-MigrationState -Contract $contract -Applied $applied

if ($Action -eq 'plan') {
    Write-Result ([pscustomobject]@{
        action = $Action
        app_slug = $contract.slug
        manifest = $contract.manifest_path
        total_migrations = $contract.migrations.Count
        applied_migrations = $state.verified.Count
        pending_migrations = $state.pending.Count
        pending = @($state.pending | ForEach-Object { $_.name })
        platform_registry = 'ready'
        status = 'planned'
    })
    exit 0
}

if ($Action -eq 'verify') {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $CoreScript -Action verify
    if ($LASTEXITCODE -ne 0) { throw 'Validação central do Ultrabase falhou.' }
    Write-Result ([pscustomobject]@{
        action = $Action
        app_slug = $contract.slug
        manifest = $contract.manifest_path
        total_migrations = $contract.migrations.Count
        applied_migrations = $state.verified.Count
        pending_migrations = $state.pending.Count
        platform_registry = 'ready'
        status = if ($state.pending.Count -eq 0) { 'verified' } else { 'pending_migrations' }
    })
    if ($state.pending.Count -gt 0) { exit 3 }
    exit 0
}

if ($state.pending.Count -eq 0) {
    Write-Result ([pscustomobject]@{
        action = $Action
        app_slug = $contract.slug
        manifest = $contract.manifest_path
        total_migrations = $contract.migrations.Count
        applied_migrations = $state.verified.Count
        pending_migrations = 0
        platform_registry = 'ready'
        backup_manifest = $backupManifest
        status = 'already_current'
    })
    exit 0
}

$destructivePending = @($state.pending | Where-Object { $_.destructive })
if ($destructivePending.Count -gt 0 -and -not $AllowDestructive) {
    throw "Há migration destrutiva pendente ($($destructivePending.name -join ', ')). O script exige rollback irmão e -AllowDestructive explícito."
}

if (-not $SkipBackup -and -not $backupManifest) {
    $backupManifest = Invoke-FullBackup
}

$commit = Get-GitCommit -Root $RepoRoot
$runId = New-MigrationRun -Slug $contract.slug -RunAction 'apply' -PendingCount $state.pending.Count -BackupManifest $backupManifest
$appliedNow = 0
try {
    foreach ($migration in $state.pending) {
        Write-Host "Aplicando $($migration.name)..." -ForegroundColor Cyan
        Invoke-DbFile -Path $migration.path | Out-Null
        Record-Migration -Contract $contract -Migration $migration -Commit $commit
        $appliedNow++
    }
    Complete-MigrationRun -RunId $runId -Status 'succeeded' -AppliedCount $appliedNow -ErrorMessage $null
} catch {
    Complete-MigrationRun -RunId $runId -Status 'failed' -AppliedCount $appliedNow -ErrorMessage $_.Exception.Message
    throw
}

$finalApplied = Get-AppliedMigrations -Slug $contract.slug
$finalState = Compare-MigrationState -Contract $contract -Applied $finalApplied
if ($finalState.pending.Count -ne 0) {
    throw "Aplicação terminou com migrations ainda pendentes: $($finalState.pending.name -join ', ')"
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $CoreScript -Action verify
if ($LASTEXITCODE -ne 0) {
    throw 'Migrations foram aplicadas, mas a verificação completa do Ultrabase falhou. Use o backup/rollback antes de qualquer cutover.'
}

Write-Result ([pscustomobject]@{
    action = $Action
    app_slug = $contract.slug
    manifest = $contract.manifest_path
    total_migrations = $contract.migrations.Count
    applied_migrations = $finalState.verified.Count
    pending_migrations = 0
    platform_registry = 'ready'
    backup_manifest = $backupManifest
    status = 'applied_and_verified'
})
