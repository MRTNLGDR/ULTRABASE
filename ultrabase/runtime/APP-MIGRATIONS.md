# Ultrabase — gate governado de migrations por app

Este documento complementa o Manual Mestre e a arquitetura multiapp. O princípio continua o mesmo: existe **um Ultrabase físico**, cada app é dono do seu namespace lógico e as migrations ficam versionadas no repositório do próprio app.

O controlador oficial é:

```text
ultrabase/runtime/Ultrabase-AppMigration.ps1
```

Ele não inicia uma segunda stack Supabase CLI. Ele usa o runtime Docker já instalado, chama o `supabase-db` existente e mantém a operação no mesmo banco físico.

## Contrato obrigatório do app

Na raiz do app deve existir `ultrabase.app.json`, validado também por `ultrabase/runtime/ultrabase.app.schema.json`.

Exemplo:

```json
{
  "schema_version": 1,
  "app_slug": "ach",
  "display_name": "Artistic Career Hub",
  "table_prefix": "ach_",
  "migrations_path": "supabase/migrations",
  "database_owner": "Ultrabase Local",
  "source_repository": "https://github.com/example/ach",
  "allow_anonymous": false,
  "buckets": ["ach-files"],
  "edge_functions": ["ach-sync"],
  "shared_dependencies": ["auth.users"]
}
```

Regras principais:

- `app_slug` é minúsculo, imutável e exclusivo;
- `table_prefix` é exatamente `<app_slug>_`;
- nomes externos usam `<app-slug>-...`;
- `migrations_path` é relativo à raiz do app e não pode escapar dela;
- URL de repositório é opcional e não pode carregar credencial embutida;
- `allow_anonymous` é `false` por padrão; se continuar falso, o gate reprova grants de tabela para `anon` no namespace do app;
- migrations seguem `<timestamp>_<app_slug>_<mudanca>.sql`;
- migration aplicada e rollback versionado tornam-se imutáveis por SHA-256.

## Quatro ações

Somente validação estática, sem tocar no runtime:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File ultrabase\runtime\Ultrabase-AppMigration.ps1 `
  -Action validate `
  -AppRoot D:\CAMINHO\DO\APP
```

Plano contra o banco atual, sem aplicar migration nem registrar app novo:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File ultrabase\runtime\Ultrabase-AppMigration.ps1 `
  -Action plan `
  -AppRoot D:\CAMINHO\DO\APP
```

Aplicação governada:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File ultrabase\runtime\Ultrabase-AppMigration.ps1 `
  -Action apply `
  -AppRoot D:\CAMINHO\DO\APP
```

Verificação posterior:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File ultrabase\runtime\Ultrabase-AppMigration.ps1 `
  -Action verify `
  -AppRoot D:\CAMINHO\DO\APP
```

Para automação, acrescente `-Json`.

## O que o gate bloqueia antes do banco

O validador recusa, entre outros:

- slug reservado ou prefixo divergente;
- migration com nome incorreto;
- migration vazia;
- `migrations_path` absoluto ou com path traversal;
- credencial conhecida embutida no SQL;
- administração de role, usuário, database, schema ou extension por um app;
- DDL/DML direto em schemas internos (`auth`, `storage`, `realtime`, `extensions`, `supabase_functions`, `vault`, `graphql`);
- criação/alteração de objeto `public.*` fora do prefixo do app;
- policy, trigger, grant/revoke ou publicação Realtime apontando para tabela de outro prefixo;
- `BEGIN`/`COMMIT` manual ou `CONCURRENTLY`, porque quebrariam a atomicidade controlada pelo gate.

Referenciar `auth.users`, `auth.uid()` e criar policy em `storage.objects` continua permitido. Alterar diretamente tabelas internas não é.

## O que `verify` prova no runtime

Além da verificação central já existente do Ultrabase, o gate confirma o contrato do app depois da aplicação:

- todas as tabelas/partitioned tables `public.<app_slug>_*` têm RLS habilitado;
- quando `allow_anonymous=false`, nenhuma tabela do namespace possui grant para `anon`;
- todos os buckets declarados no manifesto existem no Storage;
- todas as Edge Functions declaradas possuem `docker/volumes/functions/<nome>/index.ts` no runtime.

Por isso `applied_and_verified` não significa apenas “o SQL executou”: significa que migration, ledger e invariantes mínimas do domínio foram verificados.

## Operação destrutiva

O controlador detecta `DROP`, `TRUNCATE`, remoção de coluna/constraint e exclusão direta de dados do domínio.

Uma migration destrutiva precisa de arquivo irmão:

```text
20260809090000_ach_remove_legacy.sql
20260809090000_ach_remove_legacy.rollback.sql
```

O rollback passa pelo mesmo isolamento de namespace e recebe SHA-256 próprio. Mesmo com rollback válido, `apply` ainda exige `-AllowDestructive` explícito.

## Backup obrigatório

Antes de qualquer migration pendente, o controlador chama o backup oficial do Ultrabase. A aplicação é interrompida se não surgir um novo manifesto de backup.

Esse backup já inclui o dump lógico, roles, Storage físico e manifesto; segredos continuam fora do Git e precisam permanecer guardados separadamente, conforme o Manual Mestre.

Não existe flag para pular backup no `apply` normal.

## Ledger e atomicidade

A migration de plataforma `ultrabase/migrations/20260809022000_core_app_registry.sql` cria:

- `core_platform_migrations`;
- `core_applications`;
- `core_app_migrations`;
- `core_app_migration_runs`.

Essas tabelas administrativas têm RLS, nenhum grant para `anon`/`authenticated`, e os dois ledgers de checksum são append-only por trigger.

Para cada migration de app, o controlador monta uma única transação PostgreSQL contendo:

1. o SQL da migration;
2. o registro do SHA-256 da migration;
3. o SHA-256 do rollback, quando existir;
4. commit do Ultrabase e commit do app quando Git estiver disponível.

Assim, não existe estado normal em que o schema tenha sido aplicado mas o ledger correspondente tenha falhado separadamente.

## Estado pré-existente sem ledger

Se já existirem objetos `public` com o prefixo do app, mas o app não estiver registrado no ledger, o controlador **não adota automaticamente** esse schema. Ele falha de forma explícita.

Isso é intencional: marcar migrations como aplicadas sem provar equivalência seria fabricar histórico. Um domínio legado precisa de migração/adoção planejada e verificável.

## CI do próprio Ultrabase

O workflow `.github/workflows/ultrabase-app-governance.yml` prova duas camadas:

- Windows/PowerShell: parser + casos positivos e negativos do gate estático;
- PostgreSQL 17: replay idempotente da migration core, RLS, grants, constraints e imutabilidade dos ledgers.

Nenhuma mudança deste subsistema deve ser considerada concluída se esse workflow estiver vermelho.
