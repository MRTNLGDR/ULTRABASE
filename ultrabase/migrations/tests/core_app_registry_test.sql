\set ON_ERROR_STOP on

begin;

do $$
declare
  missing text[];
begin
  select array_agg(name) into missing
  from (values
    ('core_platform_migrations'),
    ('core_applications'),
    ('core_app_migrations'),
    ('core_app_migration_runs')
  ) expected(name)
  where to_regclass('public.' || name) is null;

  if missing is not null then
    raise exception 'missing core tables: %', missing;
  end if;
end;
$$;

do $$
declare
  not_rls text[];
begin
  select array_agg(c.relname) into not_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('core_platform_migrations','core_applications','core_app_migrations','core_app_migration_runs')
    and not c.relrowsecurity;

  if not_rls is not null then
    raise exception 'RLS disabled on: %', not_rls;
  end if;
end;
$$;

do $$
begin
  if has_table_privilege('anon', 'public.core_applications', 'select')
     or has_table_privilege('authenticated', 'public.core_applications', 'select')
     or has_table_privilege('anon', 'public.core_app_migrations', 'insert')
     or has_table_privilege('authenticated', 'public.core_app_migrations', 'insert') then
    raise exception 'client roles unexpectedly have core registry privileges';
  end if;
end;
$$;

insert into public.core_applications (
  app_slug, display_name, table_prefix, manifest_sha256, migrations_path
) values (
  'demo', 'Demo', 'demo_', repeat('a', 64), 'supabase/migrations'
);

insert into public.core_app_migrations (
  app_slug, migration_name, migration_sha256, destructive, rollback_name, rollback_sha256
) values (
  'demo', '20260809030000_demo_create_items.sql', repeat('b', 64), false, null, null
);

do $$
begin
  begin
    update public.core_app_migrations
    set migration_sha256 = repeat('c', 64)
    where app_slug = 'demo';
    raise exception 'immutable app migration ledger accepted update';
  exception
    when raise_exception then
      if sqlerrm = 'immutable app migration ledger accepted update' then
        raise;
      end if;
  end;
end;
$$;

insert into public.core_platform_migrations (migration_name, migration_sha256)
values ('20260809022000_core_app_registry.sql', repeat('d', 64));

do $$
begin
  begin
    delete from public.core_platform_migrations
    where migration_name = '20260809022000_core_app_registry.sql';
    raise exception 'immutable platform ledger accepted delete';
  exception
    when raise_exception then
      if sqlerrm = 'immutable platform ledger accepted delete' then
        raise;
      end if;
  end;
end;
$$;

do $$
begin
  begin
    insert into public.core_applications (
      app_slug, display_name, table_prefix, manifest_sha256, migrations_path
    ) values ('wrong', 'Wrong', 'another_', repeat('e', 64), 'supabase/migrations');
    raise exception 'prefix mismatch constraint was not enforced';
  exception
    when check_violation then null;
  end;
end;
$$;

do $$
begin
  begin
    insert into public.core_app_migrations (
      app_slug, migration_name, migration_sha256, destructive
    ) values (
      'demo', '20260809030100_demo_drop_items.sql', repeat('f', 64), true
    );
    raise exception 'destructive migration without rollback was accepted';
  exception
    when check_violation then null;
  end;
end;
$$;

do $$
declare
  run_id uuid;
begin
  insert into public.core_app_migration_runs (app_slug, action, status, pending_count)
  values ('demo', 'apply', 'running', 1)
  returning id into run_id;

  update public.core_app_migration_runs
  set status = 'succeeded', applied_count = 1, finished_at = now()
  where id = run_id;

  if not exists (
    select 1 from public.core_app_migration_runs
    where id = run_id and status = 'succeeded' and applied_count = 1
  ) then
    raise exception 'migration run audit row did not update';
  end if;
end;
$$;

rollback;
