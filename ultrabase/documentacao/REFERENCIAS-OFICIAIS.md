# Ultrabase — referências oficiais verificadas

As referências abaixo pertencem ao projeto oficial Supabase, base open source do Ultrabase. A fonte offline equivalente está dentro de `apps/docs/content` neste repositório.

| Assunto | Referência online oficial | Fonte offline |
|---|---|---|
| Visão de self-hosting e responsabilidades | <https://supabase.com/docs/guides/self-hosting> | `apps/docs/content/guides/self-hosting.mdx` |
| Instalação, portas, URLs, chaves, SMTP, HTTPS e operação Docker | <https://supabase.com/docs/guides/self-hosting/docker> | `apps/docs/content/guides/self-hosting/docker.mdx` |
| Chaves publicáveis e secretas | <https://supabase.com/docs/guides/getting-started/api-keys> | `apps/docs/content/guides/getting-started/api-keys.mdx` |
| Conexão ao PostgreSQL e modos do pool | <https://supabase.com/docs/guides/database/connecting-to-postgres> | `apps/docs/content/guides/database/connecting-to-postgres.mdx` |
| Row Level Security | <https://supabase.com/docs/guides/database/postgres/row-level-security> | `apps/docs/content/guides/database/postgres/row-level-security.mdx` |
| Auth | <https://supabase.com/docs/guides/auth> | `apps/docs/content/guides/auth.mdx` |
| Arquitetura do Auth | <https://supabase.com/docs/guides/auth/architecture> | `apps/docs/content/guides/auth/architecture.mdx` |
| Configuração do Auth self-hosted | <https://supabase.com/docs/guides/self-hosting/auth/config> | página gerada online; variáveis relacionadas aparecem em `docker/.env.example` e nos guias self-hosted do snapshot |
| Storage e policies | <https://supabase.com/docs/guides/storage/security/access-control> | `apps/docs/content/guides/storage/security/access-control.mdx` |
| Realtime | <https://supabase.com/docs/guides/realtime> | `apps/docs/content/guides/realtime.mdx` |
| Mudanças do Postgres por Realtime | <https://supabase.com/docs/guides/realtime/postgres-changes> | `apps/docs/content/guides/realtime/postgres-changes.mdx` |
| Edge Functions self-hosted | <https://supabase.com/docs/guides/self-hosting/self-hosted-functions> | `apps/docs/content/guides/self-hosting/self-hosted-functions.mdx` |
| Segredos de Functions | <https://supabase.com/docs/guides/functions/secrets> | `apps/docs/content/guides/functions/secrets.mdx` |
| Migrations | <https://supabase.com/docs/guides/deployment/database-migrations> | `apps/docs/content/guides/deployment/database-migrations.mdx` |
| Seed de desenvolvimento | <https://supabase.com/docs/guides/local-development/seeding-your-database> | `apps/docs/content/guides/local-development/seeding-your-database.mdx` |
| Desenvolvimento local | <https://supabase.com/docs/guides/local-development> | `apps/docs/content/guides/local-development.mdx` |
| Backups | <https://supabase.com/docs/guides/platform/backups> | `apps/docs/content/guides/platform/backups.mdx` |
| Restauração para self-hosted | <https://supabase.com/docs/guides/self-hosting/restore-from-platform> | `apps/docs/content/guides/self-hosting/restore-from-platform.mdx` |

## Notas de interpretação para o Ultrabase

- O Ultrabase é a variante self-hosted via Docker Compose, não a plataforma gerenciada.
- Conteúdo marcado como exclusivo de plano ou plataforma hospedada não passa a existir no self-hosted apenas por aparecer na documentação geral.
- Na instalação local, o host oficial `<your-domain>` corresponde a `127.0.0.1` e a entrada principal usa a porta `8000`.
- As portas locais `5432` e `6543` pertencem ao Supavisor, respectivamente em modo sessão e transação.
- O pacote offline fica preso ao commit declarado no manifesto; links online podem mudar depois dele.
- Algumas referências de API são geradas a partir de repositórios de cada serviço e não têm um arquivo MDX individual em `apps/docs/content`; a tabela deixa esses casos explícitos em vez de inventar um caminho local.
