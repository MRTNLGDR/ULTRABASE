-- Ultrabase platform migration: governed multi-app registry
-- Owned by the Ultrabase platform, not by any consumer application.
-- Application domain objects continue to use their own <app_slug>_ prefix.

begin;

create table if not exists public.core_applications (
  app_slug text primary key,
  display_name text not null,
  table_prefix text not null unique,
  schema_version integer not null default 1 check (schema_version > 0),
  source_repository text,
  manifest_sha256 text not null,
  migrations_path text not null,
  buckets jsonb not null default '[]'::jsonb,
  edge_functions jsonb not null default '[]'::jsonb,
  shared_dependencies jsonb not null default '[]'::jsonb,
  status text not null default 'active'
    check (status in ('active', 'paused', 'retired')),
  registered_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint core_applications_slug_format
    check (app_slug ~ '^[a-z][a-z0-9_]{1,23}$'),
  constraint core_applications_prefix_format
    check (table_prefix = app_slug || '_')
);

create table if not exists public.core_app_migrations (
  app_slug text not null references public.core_applications(app_slug) on delete restrict,
  migration_name text not null,
  migration_sha256 text not null,
  destructive boolean not null default false,
  rollback_name text,
  applied_at timestamptz not null default now(),
  applied_by text not null default current_user,
  ultrabase_commit text,
  metadata jsonb not null default '{}'::jsonb,
  primary key (app_slug, migration_name),
  constraint core_app_migrations_name_format
    check (migration_name ~ '^[0-9]{14}_[a-z][a-z0-9_]{1,23}_.+\.sql$'),
  constraint core_app_migrations_sha_format
    check (migration_sha256 ~ '^[0-9a-f]{64}$')
);

create table if not exists public.core_app_migration_runs (
  id uuid primary key default gen_random_uuid(),
  app_slug text not null references public.core_applications(app_slug) on delete restrict,
  action text not null check (action in ('apply', 'verify', 'adopt')),
  status text not null check (status in ('running', 'succeeded', 'failed')),
  pending_count integer not null default 0 check (pending_count >= 0),
  applied_count integer not null default 0 check (applied_count >= 0),
  backup_manifest text,
  error_message text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists core_app_migrations_applied_at_idx
  on public.core_app_migrations (applied_at desc);

create index if not exists core_app_migration_runs_app_started_idx
  on public.core_app_migration_runs (app_slug, started_at desc);

create or replace function public.core_touch_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists core_applications_touch_updated_at on public.core_applications;
create trigger core_applications_touch_updated_at
before update on public.core_applications
for each row execute function public.core_touch_updated_at();

-- Platform registry is administrative state. It is not part of the client Data API.
alter table public.core_applications enable row level security;
alter table public.core_app_migrations enable row level security;
alter table public.core_app_migration_runs enable row level security;

revoke all on table public.core_applications from anon, authenticated;
revoke all on table public.core_app_migrations from anon, authenticated;
revoke all on table public.core_app_migration_runs from anon, authenticated;
revoke all on function public.core_touch_updated_at() from public, anon, authenticated;

comment on table public.core_applications is
  'Ultrabase-governed registry of logical applications sharing this physical installation.';
comment on table public.core_app_migrations is
  'Immutable checksum ledger of application migrations applied through Ultrabase-AppMigration.ps1.';
comment on table public.core_app_migration_runs is
  'Operational audit trail for migration apply/verify/adopt runs.';

commit;
