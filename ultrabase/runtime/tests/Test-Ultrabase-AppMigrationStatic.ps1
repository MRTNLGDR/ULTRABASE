[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Target = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Ultrabase-AppMigration.ps1'))
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ("ultrabase-appmigration-tests-" + [guid]::NewGuid().ToString('N'))
$Passed = 0
$Failed = 0

function New-Fixture {
    param(
        [string]$Name,
        [string]$Slug = 'demo',
        [string]$Prefix = 'demo_',
        [string]$MigrationName = '20260809030000_demo_create_items.sql',
        [string]$Sql = 'create table public.demo_items (id uuid primary key default gen_random_uuid(), owner_id uuid references auth.users(id));',
        [string[]]$Buckets = @('demo-files'),
        [string[]]$EdgeFunctions = @('demo-sync'),
        [string]$MigrationsPath = 'supabase/migrations',
        [AllowNull()][string]$SourceRepository = $null,
        [AllowNull()][string]$RollbackSql = $null
    )

    $appRoot = Join-Path $Root $Name
    $migrationDir = Join-Path $appRoot 'supabase\migrations'
    New-Item -ItemType Directory -Force -Path $migrationDir | Out-Null

    $manifest = [ordered]@{
        schema_version = 1
        app_slug = $Slug
        display_name = "Fixture $Name"
        table_prefix = $Prefix
        migrations_path = $MigrationsPath
        database_owner = 'Ultrabase Local'
        buckets = @($Buckets)
        edge_functions = @($EdgeFunctions)
        shared_dependencies = @('auth.users')
    }
    if ($null -ne $SourceRepository) { $manifest.source_repository = $SourceRepository }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $appRoot 'ultrabase.app.json') -Encoding UTF8

    if ($MigrationsPath -eq 'supabase/migrations') {
        Set-Content -LiteralPath (Join-Path $migrationDir $MigrationName) -Value $Sql -Encoding UTF8
        if ($null -ne $RollbackSql) {
            $rollbackName = [System.IO.Path]::ChangeExtension($MigrationName, $null) + '.rollback.sql'
            Set-Content -LiteralPath (Join-Path $migrationDir $rollbackName) -Value $RollbackSql -Encoding UTF8
        }
    }
    return $appRoot
}

function Assert-Validation {
    param(
        [string]$Name,
        [string]$AppRoot,
        [bool]$ShouldPass
    )

    $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Target -Action validate -AppRoot $AppRoot -Json 2>&1
    $code = $LASTEXITCODE
    $actualPass = ($code -eq 0)
    if ($actualPass -eq $ShouldPass) {
        $script:Passed++
        Write-Host "PASS $Name" -ForegroundColor Green
        return
    }

    $script:Failed++
    Write-Host "FAIL $Name (exit=$code expectedPass=$ShouldPass)" -ForegroundColor Red
    $output | ForEach-Object { Write-Host $_ }
}

try {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null

    $validSql = @'
create table public.demo_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users(id) on delete cascade
);
alter table public.demo_items enable row level security;
grant select, insert, update, delete on table public.demo_items to authenticated;
create policy demo_items_owner on public.demo_items
for select to authenticated using (owner_id = auth.uid());
create policy demo_files_read on storage.objects
for select to authenticated using (bucket_id = 'demo-files');
'@
    Assert-Validation 'valid app migration' (New-Fixture -Name 'valid' -Sql $validSql) $true

    Assert-Validation 'reserved slug rejected' (New-Fixture -Name 'reserved' -Slug 'auth' -Prefix 'auth_' -MigrationName '20260809030000_auth_create_items.sql' -Buckets @('auth-files') -EdgeFunctions @('auth-sync') -Sql 'create table public.auth_items (id uuid primary key);') $false

    Assert-Validation 'wrong table prefix rejected' (New-Fixture -Name 'wrong-prefix' -Prefix 'other_') $false

    Assert-Validation 'cross app table rejected' (New-Fixture -Name 'cross-app' -Sql 'create table public.other_items (id uuid primary key);') $false

    Assert-Validation 'cross app policy rejected' (New-Fixture -Name 'cross-policy' -Sql 'create policy bad on public.other_items for select to authenticated using (true);') $false

    Assert-Validation 'auth mutation rejected' (New-Fixture -Name 'auth-mutation' -Sql "insert into auth.users (id) values ('00000000-0000-0000-0000-000000000000');") $false

    Assert-Validation 'storage mutation rejected' (New-Fixture -Name 'storage-mutation' -Sql "insert into storage.buckets (id, name) values ('demo-files','demo-files');") $false

    Assert-Validation 'shared extension administration rejected' (New-Fixture -Name 'extension' -Sql 'create extension if not exists vector;') $false

    Assert-Validation 'explicit transaction rejected' (New-Fixture -Name 'transaction' -Sql "begin;`ncreate table public.demo_items (id uuid);`ncommit;") $false

    Assert-Validation 'non atomic concurrently rejected' (New-Fixture -Name 'concurrently' -Sql 'create index concurrently demo_items_id_idx on public.demo_items(id);') $false

    Assert-Validation 'embedded secret rejected' (New-Fixture -Name 'secret' -Sql "select 'SUPABASE_SECRET_KEY=super-secret-value';") $false

    Assert-Validation 'bucket namespace rejected' (New-Fixture -Name 'bucket' -Buckets @('other-files')) $false

    Assert-Validation 'edge function namespace rejected' (New-Fixture -Name 'edge' -EdgeFunctions @('other-sync')) $false

    Assert-Validation 'credentialed source repository rejected' (New-Fixture -Name 'repo-secret' -SourceRepository 'https://token123@github.com/example/repo.git') $false

    Assert-Validation 'migration filename rejected' (New-Fixture -Name 'bad-name' -MigrationName '20260809030000_other_create_items.sql') $false

    Assert-Validation 'path traversal rejected' (New-Fixture -Name 'path-traversal' -MigrationsPath '..\outside') $false

    $dropSql = 'drop table public.demo_old_items;'
    $rollbackSql = 'create table public.demo_old_items (id uuid primary key);'
    Assert-Validation 'destructive migration with rollback accepted' (New-Fixture -Name 'rollback-ok' -Sql $dropSql -RollbackSql $rollbackSql) $true

    Assert-Validation 'destructive migration without rollback rejected' (New-Fixture -Name 'rollback-missing' -Sql $dropSql) $false

    $badRollback = 'create table public.other_old_items (id uuid primary key);'
    Assert-Validation 'rollback outside namespace rejected' (New-Fixture -Name 'rollback-bad' -Sql $dropSql -RollbackSql $badRollback) $false

    Write-Host "`nStatic contract tests: $Passed passed, $Failed failed"
    if ($Failed -ne 0) { exit 1 }
    exit 0
} finally {
    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
