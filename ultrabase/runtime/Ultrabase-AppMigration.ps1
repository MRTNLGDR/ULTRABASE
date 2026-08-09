[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('validate', 'plan', 'apply', 'verify')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$AppRoot,

    [switch]$AllowDestructive,
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
    if ($null -eq $Value) { return 'null' }
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-JsonArray([object[]]$Items) {
    return (ConvertTo-Json -InputObject @($Items) -Compress -Depth 8)
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
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 2) {
        throw 'Ultrabase está pausado conscientemente. Retome pelo launcher oficial antes de aplicar migrations.'
    }
    if ($exitCode -ne 0) {
        throw "Ultrabase-Runtime.ps1 falhou com código $exitCode."
    }
    $health = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
    if (-not $health.ready) { throw 'Runtime Ultrabase não confirmou ready=true.' }
    return $health
}

function Invoke-DbQuery([string]$Sql) {
    $output = & docker exec supabase-db psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc $Sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Falha SQL no container supabase-db:`n$($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Invoke-DbFile([string]$Path, [switch]$SingleTransaction) {
    $remote = "/tmp/ultrabase-$([guid]::NewGuid().ToString('N')).sql"
    try {
        & docker cp $Path "supabase-db:$remote" *> $null
        if ($LASTEXITCODE -ne 0) { throw "docker cp falhou para $Path" }

        $args = @('exec', 'supabase-db', 'psql', '-X', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1')
        if ($SingleTransaction) { $args += '--single-transaction' }
        $args += @('-f', $remote)
        $output = & docker @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Migration falhou: $Path`n$($output -join [Environment]::NewLine)"
        }
        return @($output | ForEach-Object { [string]$_ })
    } finally {
        & docker exec supabase-db rm -f $remote *> $null
    }
}

function Test-CoreRegistry {
    $sql = @"
select case when
  to_regclass('public.core_platform_migrations') is not null and
  to_regclass('public.core_applications') is not null and
  to_regclass('public.core_app_migrations') is not null and
  to_regclass('public.core_app_migration_runs') is not null
then '1' else '0' end;
"@
    $result = Invoke-DbQuery $sql
    return ($result.Count -gt 0 -and $result[0].Trim() -eq '1')
}

function Assert-PlatformRegistryIntegrity {
    if (-not (Test-CoreRegistry)) { return $false }
    $name = [System.IO.Path]::GetFileName($PlatformMigration)
    $expected = Get-Sha256 -Path $PlatformMigration
    $rows = Invoke-DbQuery "select migration_sha256 from public.core_platform_migrations where migration_name=$(ConvertTo-SqlLiteral $name);"
    if ($rows.Count -eq 0) {
        throw 'Registro core existe sem checksum da migration de plataforma. Estado incompleto; não será alterado automaticamente.'
    }
    if ($rows[0].Trim() -ne $expected) {
        throw "Migration de plataforma aplicada foi modificada: $name. Crie nova migration core em vez de reescrever histórico."
    }
    return $true
}

function Invoke-PlatformRegistryMigration {
    if (-not (Test-Path -LiteralPath $PlatformMigration -PathType Leaf)) {
        throw "Migration de plataforma ausente: $PlatformMigration"
    }
    if (Test-CoreRegistry) {
        Assert-PlatformRegistryIntegrity | Out-Null
        return
    }

    Invoke-DbFile -Path $PlatformMigration | Out-Null
    if (-not (Test-CoreRegistry)) { throw 'Registro core não existe após a migration de plataforma.' }

    $name = [System.IO.Path]::GetFileName($PlatformMigration)
    $sha = Get-Sha256 -Path $PlatformMigration
    Invoke-DbQuery @"
insert into public.core_platform_migrations (migration_name, migration_sha256, metadata)
values ($(ConvertTo-SqlLiteral $name), $(ConvertTo-SqlLiteral $sha), '{"source":"Ultrabase repository"}'::jsonb);
"@ | Out-Null
    Assert-PlatformRegistryIntegrity | Out-Null
}

function Invoke-FullBackup {
    $before = @()
    if (Test-Path -LiteralPath $DockerBackupDir) {
        $before = @(Get-ChildItem -LiteralPath $DockerBackupDir -Filter '*-manifest.txt' -File | Select-Object -ExpandProperty FullName)
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $CoreScript -Action backup
    if ($LASTEXITCODE -ne 0) { throw 'Backup obrigatório falhou. Nenhuma migration será aplicada.' }

    $after = @(Get-ChildItem -LiteralPath $DockerBackupDir -Filter '*-manifest.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($after.Count -eq 0) { throw 'Backup terminou sem manifesto verificável.' }
    $manifest = $after[0].FullName
    if ($before -contains $manifest) { throw 'Nenhum novo manifesto de backup foi criado.' }
    return $manifest
}

function Assert-SqlSafe([string]$Sql, [string]$FileName, [string]$Prefix) {
    if ([string]::IsNullOrWhiteSpace($Sql)) { throw "SQL vazio: $FileName" }

    if ($Sql -match '(?im)^\s*(?:begin|commit|rollback)\s*;') {
        throw "$FileName contém controle explícito de transação. O Ultrabase aplica migration + ledger atomicamente e controla a transação."
    }
    if ($Sql -match '(?i)\bconcurrently\b') {
        throw "$FileName usa CONCURRENTLY, que não é compatível com o gate transacional atômico do Ultrabase."
    }
    if ($Sql -match '(?i)(SUPABASE_SECRET_KEY|SERVICE_ROLE_KEY|POSTGRES_PASSWORD|JWT_SECRET)\s*[:=]\s*[^\s<]+') {
        throw "$FileName parece conter segredo/credencial. Migrations nunca podem transportar segredos."
    }
    if ($Sql -match '(?is)\b(?:create|alter|drop)\s+(?:role|user|database|schema|extension)\b') {
        throw "$FileName tenta administrar role/database/schema/extension. Dependências compartilhadas pertencem à governança core do Ultrabase."
    }

    $internalMutation = '(?is)\b(?:alter\s+table|drop\s+(?:table|function|procedure|view|type)|truncate\s+(?:table\s+)?|insert\s+into|update|delete\s+from|create\s+table)\s+(?:if\s+(?:not\s+)?exists\s+)?(?:auth|storage|realtime|extensions|supabase_functions|vault|graphql)\.'
    if ($Sql -match $internalMutation) {
        throw "$FileName tenta modificar diretamente schema interno do Supabase. Referências e policies em storage.objects são permitidas; DDL/DML interno não é."
    }

    $patterns = @(
        '(?is)\bcreate\s+(?:or\s+replace\s+)?(?:table|view|materialized\s+view|function|procedure|sequence)\s+(?:if\s+not\s+exists\s+)?public\.([a-zA-Z_][a-zA-Z0-9_]*)',
        '(?is)\b(?:alter\s+table|drop\s+(?:table|view|function|procedure|sequence)|truncate\s+(?:table\s+)?|insert\s+into|update|delete\s+from)\s+(?:if\s+exists\s+)?public\.([a-zA-Z_][a-zA-Z0-9_]*)',
        '(?is)\b(?:create|alter|drop)\s+policy\b.*?\bon\s+public\.([a-zA-Z_][a-zA-Z0-9_]*)',
        '(?is)\bcreate\s+(?:constraint\s+)?trigger\b.*?\bon\s+public\.([a-zA-Z_][a-zA-Z0-9_]*)',
        '(?is)\balter\s+publication\s+supabase_realtime\s+add\s+table\s+public\.([a-zA-Z_][a-zA-Z0-9_]*)',
        '(?is)\b(?:grant|revoke)\b.*?\bon\s+(?:table\s+)?public\.([a-zA-Z_][a-zA-Z0-9_]*)'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Sql, $pattern)) {
            $name = $match.Groups[1].Value.ToLowerInvariant()
            if (-not $name.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
                throw "$FileName tenta criar/alterar public.$name fora do prefixo reservado $Prefix"
            }
        }
    }
}

function Get-MigrationDescriptor([System.IO.FileInfo]$File, [string]$Slug, [string]$Prefix) {
    $namePattern = "^[0-9]{14}_$([regex]::Escape($Slug))_.+\.sql$"
    if ($File.Name -notmatch $namePattern) {
        throw "Nome de migration inválido: $($File.Name). Use <timestamp>_${Slug}_<mudanca>.sql"
    }

    $sql = Get-Content -LiteralPath $File.FullName -Raw
    Assert-SqlSafe -Sql $sql -FileName $File.Name -Prefix $Prefix

    $destructive = ($sql -match '(?is)\b(?:drop\s+(?:table|view|function|procedure|type)|truncate\s+(?:table\s+)?|alter\s+table\b[^;]*\bdrop\s+(?:column|constraint)|delete\s+from\s+public\.)')
    $rollbackPath = [System.IO.Path]::ChangeExtension($File.FullName, $null) + '.rollback.sql'
    $rollback = if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) { $rollbackPath } else { $null }

    if ($destructive -and -not $rollback) {
        throw "$($File.Name) contém operação destrutiva e não possui rollback irmão $([System.IO.Path]::GetFileName($rollbackPath))."
    }

    $rollbackSha = $null
    if ($rollback) {
        $rollbackSql = Get-Content -LiteralPath $rollback -Raw
        Assert-SqlSafe -Sql $rollbackSql -FileName ([System.IO.Path]::GetFileName($rollback)) -Prefix $Prefix
        $rollbackSha = Get-Sha256 -Path $rollback
    }

    return [pscustomobject]@{
        name = $File.Name
        path = $File.FullName
        sha256 = Get-Sha256 -Path $File.FullName
        destructive = [bool]$destructive
        rollback_path = $rollback
        rollback_name = if ($rollback) { [System.IO.Path]::GetFileName($rollback) } else { $null }
        rollback_sha256 = $rollbackSha
    }
}

function Read-AppContract([string]$Root) {
    $manifestPath = Join-Path $Root $ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Manifesto obrigatório ausente: $manifestPath" }

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
    if ([int]$manifest.schema_version -ne 1) { throw "schema_version não suportado: $($manifest.schema_version). Esperado: 1" }

    $slug = ([string]$manifest.app_slug).ToLowerInvariant()
    if ($slug -notmatch '^[a-z][a-z0-9_]{1,23}$') { throw "app_slug inválido: $slug" }
    if ($ReservedSlugs -contains $slug) { throw "app_slug reservado pelo Ultrabase/Supabase: $slug" }

    $prefix = ([string]$manifest.table_prefix).ToLowerInvariant()
    if ($prefix -ne "${slug}_") { throw "table_prefix deve ser exatamente ${slug}_" }
    if ([string]$manifest.database_owner -ne 'Ultrabase Local') { throw 'database_owner deve ser "Ultrabase Local" para esta instalação.' }

    if ($manifest.PSObject.Properties['source_repository']) {
        $sourceRepository = [string]$manifest.source_repository
        if ($sourceRepository -match '^[a-z][a-z0-9+.-]*://[^/]*@') {
            throw 'source_repository parece conter credencial embutida. Use URL pública sem token/usuário.'
        }
    }

    $allowAnonymous = $false
    if ($manifest.PSObject.Properties['allow_anonymous']) { $allowAnonymous = [bool]$manifest.allow_anonymous }

    $migrationDir = Resolve-SafeChildPath -Base $Root -Relative ([string]$manifest.migrations_path)
    if (-not (Test-Path -LiteralPath $migrationDir -PathType Container)) { throw "Pasta de migrations não existe: $migrationDir" }

    $buckets = @()
    if ($manifest.PSObject.Properties['buckets']) { $buckets = @($manifest.buckets) }
    $externalSlug = $slug.Replace('_', '-')
    foreach ($bucket in $buckets) {
        $bucketName = [string]$bucket
        if ($bucketName -notmatch '^[a-z0-9][a-z0-9-]{1,62}$' -or -not $bucketName.StartsWith("$externalSlug-", [System.StringComparison]::Ordinal)) {
            throw "Bucket inválido ou fora do namespace do app: $bucketName"
        }
    }

    $edgeFunctions = @()
    if ($manifest.PSObject.Properties['edge_functions']) { $edgeFunctions = @($manifest.edge_functions) }
    foreach ($functionNameValue in $edgeFunctions) {
        $functionName = [string]$functionNameValue
        if ($functionName -notmatch '^[a-z0-9][a-z0-9-]{1,62}$' -or -not $functionName.StartsWith("$externalSlug-", [System.StringComparison]::Ordinal)) {
            throw "Edge Function inválida ou fora do namespace do app: $functionName"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $migrationDir -File -Filter '*.sql' |
        Where-Object { $_.Name -notlike '*.rollback.sql' } |
        Sort-Object Name)
    if ($files.Count -eq 0) { throw "Nenhuma migration encontrada em $migrationDir" }

    $migrations = @()
    foreach ($file in $files) { $migrations += Get-MigrationDescriptor -File $file -Slug $slug -Prefix $prefix }

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
        allow_anonymous = $allowAnonymous
    }
}

function Get-GitCommit([string]$Root) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $value = & git -C $Root rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$value).Trim()
}

function Get-AppRegistration([string]$Slug) {
    $rows = Invoke-DbQuery "select table_prefix || E'\t' || manifest_sha256 from public.core_applications where app_slug=$(ConvertTo-SqlLiteral $Slug);"
    if ($rows.Count -eq 0) { return $null }
    $parts = $rows[0] -split "`t", 2
    return [pscustomobject]@{ table_prefix = $parts[0]; manifest_sha256 = if ($parts.Count -gt 1) { $parts[1] } else { '' } }
}

function Assert-PrefixAvailable([string]$Slug, [string]$Prefix) {
    $rows = Invoke-DbQuery "select app_slug from public.core_applications where table_prefix=$(ConvertTo-SqlLiteral $Prefix) and app_slug<>$(ConvertTo-SqlLiteral $Slug);"
    if ($rows.Count -gt 0) { throw "table_prefix $Prefix já pertence ao app $($rows[0])." }
}

function Get-PrefixObjectCount([string]$Prefix) {
    $rows = Invoke-DbQuery "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S') and starts_with(c.relname, $(ConvertTo-SqlLiteral $Prefix));"
    return [int]$rows[0]
}

function Register-App([object]$Contract) {
    Assert-PrefixAvailable -Slug $Contract.slug -Prefix $Contract.prefix
    $m = $Contract.manifest
    $sourceRepository = $null
    if ($m.PSObject.Properties['source_repository'] -and -not [string]::IsNullOrWhiteSpace([string]$m.source_repository)) {
        $sourceRepository = [string]$m.source_repository
    }
    $dependencies = @()
    if ($m.PSObject.Properties['shared_dependencies']) { $dependencies = @($m.shared_dependencies) }

    $bucketJson = ConvertTo-JsonArray -Items $Contract.buckets
    $edgeJson = ConvertTo-JsonArray -Items $Contract.edge_functions
    $depsJson = ConvertTo-JsonArray -Items $dependencies
    $allowAnonymousSql = if ($Contract.allow_anonymous) { 'true' } else { 'false' }

    Invoke-DbQuery @"
insert into public.core_applications (
  app_slug, display_name, table_prefix, schema_version, source_repository,
  manifest_sha256, migrations_path, allow_anonymous, buckets, edge_functions, shared_dependencies, status
) values (
  $(ConvertTo-SqlLiteral $Contract.slug),
  $(ConvertTo-SqlLiteral ([string]$m.display_name)),
  $(ConvertTo-SqlLiteral $Contract.prefix),
  1,
  $(ConvertTo-SqlLiteral $sourceRepository),
  $(ConvertTo-SqlLiteral $Contract.manifest_sha256),
  $(ConvertTo-SqlLiteral ([string]$m.migrations_path)),
  $allowAnonymousSql,
  $(ConvertTo-SqlLiteral $bucketJson)::jsonb,
  $(ConvertTo-SqlLiteral $edgeJson)::jsonb,
  $(ConvertTo-SqlLiteral $depsJson)::jsonb,
  'active'
)
on conflict (app_slug) do update set
  display_name=excluded.display_name,
  manifest_sha256=excluded.manifest_sha256,
  migrations_path=excluded.migrations_path,
  allow_anonymous=excluded.allow_anonymous,
  buckets=excluded.buckets,
  edge_functions=excluded.edge_functions,
  shared_dependencies=excluded.shared_dependencies,
  source_repository=coalesce(excluded.source_repository, public.core_applications.source_repository),
  updated_at=now()
where public.core_applications.table_prefix=excluded.table_prefix;
"@ | Out-Null

    $registered = Get-AppRegistration -Slug $Contract.slug
    if ($null -eq $registered -or $registered.table_prefix -ne $Contract.prefix) {
        throw "Falha ao reservar namespace do app $($Contract.slug)."
    }
}

function Get-AppliedMigrations([string]$Slug) {
    $rows = Invoke-DbQuery "select migration_name || E'\t' || migration_sha256 || E'\t' || coalesce(rollback_sha256,'') from public.core_app_migrations where app_slug=$(ConvertTo-SqlLiteral $Slug) order by migration_name;"
    $map = @{}
    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        $parts = $row -split "`t", 3
        $map[$parts[0]] = [pscustomobject]@{
            migration_sha256 = $parts[1]
            rollback_sha256 = if ($parts.Count -gt 2 -and -not [string]::IsNullOrWhiteSpace($parts[2])) { $parts[2] } else { $null }
        }
    }
    return $map
}

function Compare-MigrationState([object]$Contract, [hashtable]$Applied) {
    $pending = @()
    $verified = @()
    $currentNames = @($Contract.migrations | ForEach-Object { $_.name })

    foreach ($migration in $Contract.migrations) {
        if (-not $Applied.ContainsKey($migration.name)) {
            $pending += $migration
            continue
        }
        $record = $Applied[$migration.name]
        if ($record.migration_sha256 -ne $migration.sha256) {
            throw "Migration aplicada foi modificada: $($migration.name). Crie nova migration em vez de reescrever histórico."
        }
        if ($record.rollback_sha256 -ne $migration.rollback_sha256) {
            throw "Rollback versionado mudou após aplicação: $($migration.rollback_name). Rollback também é artefato imutável."
        }
        $verified += $migration
    }

    $missing = @($Applied.Keys | Where-Object { $_ -notin $currentNames })
    if ($missing.Count -gt 0) {
        throw "Migrations aplicadas sumiram do repositório: $($missing -join ', '). Histórico aplicado não pode ser apagado."
    }
    return [pscustomobject]@{ pending = $pending; verified = $verified }
}

function Assert-AppRuntimeContract([object]$Contract) {
    $tablesWithoutRls = Invoke-DbQuery @"
select c.relname
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relkind in ('r','p')
  and starts_with(c.relname, $(ConvertTo-SqlLiteral $Contract.prefix))
  and not c.relrowsecurity
order by c.relname;
"@
    $tablesWithoutRls = @($tablesWithoutRls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($tablesWithoutRls.Count -gt 0) {
        throw "Tabelas do app sem RLS: $($tablesWithoutRls -join ', ')"
    }

    if (-not $Contract.allow_anonymous) {
        $anonGrants = Invoke-DbQuery @"
select distinct table_name
from information_schema.role_table_grants
where grantee='anon'
  and table_schema='public'
  and starts_with(table_name, $(ConvertTo-SqlLiteral $Contract.prefix))
order by table_name;
"@
        $anonGrants = @($anonGrants | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($anonGrants.Count -gt 0) {
            throw "allow_anonymous=false, mas anon possui grants em: $($anonGrants -join ', ')"
        }
    }

    $missingBuckets = @()
    foreach ($bucket in $Contract.buckets) {
        $rows = Invoke-DbQuery "select count(*) from storage.buckets where id=$(ConvertTo-SqlLiteral ([string]$bucket));"
        if ([int]$rows[0] -ne 1) { $missingBuckets += [string]$bucket }
    }
    if ($missingBuckets.Count -gt 0) {
        throw "Buckets declarados ainda não existem no Storage: $($missingBuckets -join ', '). Crie-os pelo Studio/API, não por DML direto no schema storage."
    }

    $missingFunctions = @()
    foreach ($functionName in $Contract.edge_functions) {
        $indexPath = Join-Path $RepoRoot ("docker\volumes\functions\$functionName\index.ts")
        if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { $missingFunctions += [string]$functionName }
    }
    if ($missingFunctions.Count -gt 0) {
        throw "Edge Functions declaradas não estão implantadas no runtime: $($missingFunctions -join ', ')"
    }
}

function New-MigrationRun([string]$Slug, [int]$PendingCount, [string]$BackupManifest) {
    $rows = Invoke-DbQuery @"
insert into public.core_app_migration_runs (app_slug, action, status, pending_count, backup_manifest)
values ($(ConvertTo-SqlLiteral $Slug), 'apply', 'running', $PendingCount, $(ConvertTo-SqlLiteral $BackupManifest))
returning id::text;
"@
    if ($rows.Count -eq 0) { throw 'Não foi possível criar registro da execução.' }
    return $rows[0].Trim()
}

function Complete-MigrationRun([string]$RunId, [string]$Status, [int]$AppliedCount, [AllowNull()][string]$ErrorMessage) {
    Invoke-DbQuery @"
update public.core_app_migration_runs
set status=$(ConvertTo-SqlLiteral $Status), applied_count=$AppliedCount,
    error_message=$(ConvertTo-SqlLiteral $ErrorMessage), finished_at=now()
where id=$(ConvertTo-SqlLiteral $RunId)::uuid;
"@ | Out-Null
}

function Invoke-AppMigrationAtomic([object]$Contract, [object]$Migration, [AllowNull()][string]$UltrabaseCommit, [AllowNull()][string]$AppCommit) {
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ultrabase-app-" + [guid]::NewGuid().ToString('N') + '.sql')
    try {
        $sql = Get-Content -LiteralPath $Migration.path -Raw
        $metadata = [ordered]@{ manifest_sha256 = $Contract.manifest_sha256 } | ConvertTo-Json -Compress
        $destructiveSql = if ($Migration.destructive) { 'true' } else { 'false' }
        $ledger = @"

-- Ultrabase atomic migration ledger entry. Runs in the same transaction as the migration above.
insert into public.core_app_migrations (
  app_slug, migration_name, migration_sha256, destructive, rollback_name, rollback_sha256,
  ultrabase_commit, app_commit, metadata
) values (
  $(ConvertTo-SqlLiteral $Contract.slug),
  $(ConvertTo-SqlLiteral $Migration.name),
  $(ConvertTo-SqlLiteral $Migration.sha256),
  $destructiveSql,
  $(ConvertTo-SqlLiteral $Migration.rollback_name),
  $(ConvertTo-SqlLiteral $Migration.rollback_sha256),
  $(ConvertTo-SqlLiteral $UltrabaseCommit),
  $(ConvertTo-SqlLiteral $AppCommit),
  $(ConvertTo-SqlLiteral $metadata)::jsonb
);
"@
        [System.IO.File]::WriteAllText($tempFile, $sql + $ledger, [System.Text.UTF8Encoding]::new($false))
        Invoke-DbFile -Path $tempFile -SingleTransaction | Out-Null
    } finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }
}

function New-Result([string]$Status, [object]$Contract, [int]$AppliedCount, [int]$PendingCount, [string]$RegistryState, [AllowNull()][string]$BackupManifest, [object[]]$PendingNames) {
    return [pscustomobject]@{
        action = $Action
        status = $Status
        app_slug = $Contract.slug
        manifest = $Contract.manifest_path
        total_migrations = $Contract.migrations.Count
        applied_migrations = $AppliedCount
        pending_migrations = $PendingCount
        pending = @($PendingNames)
        platform_registry = $RegistryState
        backup_manifest = $BackupManifest
    }
}

function Write-Result([object]$Result) {
    if ($Json) { $Result | ConvertTo-Json -Depth 12; return }
    Write-Host ''
    Write-Host 'Ultrabase App Migration' -ForegroundColor Magenta
    Write-Host "Ação:          $($Result.action)"
    Write-Host "App:           $($Result.app_slug)"
    Write-Host "Migrations:    $($Result.total_migrations)"
    Write-Host "Aplicadas:     $($Result.applied_migrations)"
    Write-Host "Pendentes:     $($Result.pending_migrations)"
    Write-Host "Registro core: $($Result.platform_registry)"
    if ($Result.backup_manifest) { Write-Host "Backup:        $($Result.backup_manifest)" }
    Write-Host "Estado:        $($Result.status)" -ForegroundColor Green
}

$appPath = Resolve-ExistingDirectory -Path $AppRoot
$contract = Read-AppContract -Root $appPath

if ($Action -eq 'validate') {
    Write-Result (New-Result -Status 'valid' -Contract $contract -AppliedCount 0 -PendingCount $contract.migrations.Count -RegistryState 'not_checked' -BackupManifest $null -PendingNames @($contract.migrations.name))
    exit 0
}

Invoke-RuntimeEnsure | Out-Null
$registryExists = Test-CoreRegistry

if (-not $registryExists) {
    if ($Action -eq 'verify') { throw 'Registro core ainda não está instalado; não há como verificar ledger de migrations.' }
    if ($Action -eq 'plan') {
        $existingObjects = Get-PrefixObjectCount -Prefix $contract.prefix
        if ($existingObjects -gt 0) {
            throw "Namespace $($contract.prefix) já possui $existingObjects objeto(s), mas não existe ledger core. Adoção automática foi bloqueada."
        }
        Write-Result (New-Result -Status 'planned' -Contract $contract -AppliedCount 0 -PendingCount $contract.migrations.Count -RegistryState 'pending_install' -BackupManifest $null -PendingNames @($contract.migrations.name))
        exit 0
    }
}

$backupManifest = $null
if ($Action -eq 'apply' -and -not $registryExists) {
    $existingObjects = Get-PrefixObjectCount -Prefix $contract.prefix
    if ($existingObjects -gt 0) { throw "Namespace $($contract.prefix) já possui objetos sem ledger; aplicação automática bloqueada." }
    $backupManifest = Invoke-FullBackup
    Invoke-PlatformRegistryMigration
    $registryExists = $true
} else {
    Assert-PlatformRegistryIntegrity | Out-Null
}

$registration = Get-AppRegistration -Slug $contract.slug
if ($null -ne $registration -and $registration.table_prefix -ne $contract.prefix) {
    throw "app_slug $($contract.slug) já está registrado com prefixo diferente: $($registration.table_prefix)"
}

if ($Action -eq 'plan' -and $null -eq $registration) {
    Assert-PrefixAvailable -Slug $contract.slug -Prefix $contract.prefix
    $existingObjects = Get-PrefixObjectCount -Prefix $contract.prefix
    if ($existingObjects -gt 0) { throw "Namespace $($contract.prefix) possui objetos sem registro do app; adoção automática bloqueada." }
    Write-Result (New-Result -Status 'planned' -Contract $contract -AppliedCount 0 -PendingCount $contract.migrations.Count -RegistryState 'ready_app_unregistered' -BackupManifest $null -PendingNames @($contract.migrations.name))
    exit 0
}

if ($Action -eq 'verify' -and $null -eq $registration) { throw "App $($contract.slug) não está registrado no Ultrabase." }

if ($Action -eq 'apply' -and $null -eq $registration) {
    Assert-PrefixAvailable -Slug $contract.slug -Prefix $contract.prefix
    $existingObjects = Get-PrefixObjectCount -Prefix $contract.prefix
    if ($existingObjects -gt 0) { throw "Namespace $($contract.prefix) possui objetos sem ledger; registro automático bloqueado." }
}

$applied = Get-AppliedMigrations -Slug $contract.slug
$state = Compare-MigrationState -Contract $contract -Applied $applied

if ($Action -eq 'plan') {
    Write-Result (New-Result -Status 'planned' -Contract $contract -AppliedCount $state.verified.Count -PendingCount $state.pending.Count -RegistryState 'ready' -BackupManifest $null -PendingNames @($state.pending.name))
    exit 0
}

if ($Action -eq 'verify') {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $CoreScript -Action verify
    if ($LASTEXITCODE -ne 0) { throw 'Validação central do Ultrabase falhou.' }
    Assert-AppRuntimeContract -Contract $contract
    $status = if ($state.pending.Count -eq 0) { 'verified' } else { 'pending_migrations' }
    Write-Result (New-Result -Status $status -Contract $contract -AppliedCount $state.verified.Count -PendingCount $state.pending.Count -RegistryState 'ready' -BackupManifest $null -PendingNames @($state.pending.name))
    if ($state.pending.Count -gt 0) { exit 3 }
    exit 0
}

$destructivePending = @($state.pending | Where-Object { $_.destructive })
if ($destructivePending.Count -gt 0 -and -not $AllowDestructive) {
    throw "Migration destrutiva pendente: $($destructivePending.name -join ', '). Rollback já foi validado, mas -AllowDestructive é obrigatório."
}

if ($state.pending.Count -eq 0) {
    Register-App -Contract $contract
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $CoreScript -Action verify
    if ($LASTEXITCODE -ne 0) { throw 'Validação central do Ultrabase falhou.' }
    Assert-AppRuntimeContract -Contract $contract
    Write-Result (New-Result -Status 'already_current_verified' -Contract $contract -AppliedCount $state.verified.Count -PendingCount 0 -RegistryState 'ready' -BackupManifest $backupManifest -PendingNames @())
    exit 0
}

if (-not $backupManifest) { $backupManifest = Invoke-FullBackup }
Register-App -Contract $contract

$ultrabaseCommit = Get-GitCommit -Root $RepoRoot
$appCommit = Get-GitCommit -Root $contract.root
$runId = New-MigrationRun -Slug $contract.slug -PendingCount $state.pending.Count -BackupManifest $backupManifest
$appliedNow = 0
$finalState = $null
try {
    foreach ($migration in $state.pending) {
        Write-Host "Aplicando $($migration.name)..." -ForegroundColor Cyan
        Invoke-AppMigrationAtomic -Contract $contract -Migration $migration -UltrabaseCommit $ultrabaseCommit -AppCommit $appCommit
        $appliedNow++
    }

    $finalApplied = Get-AppliedMigrations -Slug $contract.slug
    $finalState = Compare-MigrationState -Contract $contract -Applied $finalApplied
    if ($finalState.pending.Count -ne 0) { throw "Aplicação terminou com migrations pendentes: $($finalState.pending.name -join ', ')" }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $CoreScript -Action verify
    if ($LASTEXITCODE -ne 0) { throw 'Migrations aplicadas, mas a verificação central do Ultrabase falhou.' }
    Assert-AppRuntimeContract -Contract $contract

    Complete-MigrationRun -RunId $runId -Status 'succeeded' -AppliedCount $appliedNow -ErrorMessage $null
} catch {
    Complete-MigrationRun -RunId $runId -Status 'failed' -AppliedCount $appliedNow -ErrorMessage $_.Exception.Message
    throw
}

Write-Result (New-Result -Status 'applied_and_verified' -Contract $contract -AppliedCount $finalState.verified.Count -PendingCount 0 -RegistryState 'ready' -BackupManifest $backupManifest -PendingNames @())
