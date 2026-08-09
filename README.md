<p align="center">
  <img src="apps/studio/public/img/supabase-logo.svg" alt="Ultrabase" width="360">
</p>

<h1 align="center">ULTRABASE</h1>

<p align="center"><strong>Sua plataforma Postgres completa, self-hosted, local-first e compatível com o ecossistema Supabase.</strong></p>

<p align="center">
  <a href="https://github.com/MRTNLGDR/ULTRABASE/actions/workflows/ultrabase-self-hosted-acceptance.yml"><img alt="Real self-hosted acceptance" src="https://github.com/MRTNLGDR/ULTRABASE/actions/workflows/ultrabase-self-hosted-acceptance.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="Apache 2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg"></a>
</p>

## O que é

O **Ultrabase** é uma distribuição independente do stack open source do Supabase, preparada para operar como backend próprio em uma máquina ou servidor sob seu controle. O projeto conserva compatibilidade com os clientes e protocolos do ecossistema Supabase, acrescentando instalação Windows em um clique, identidade visual Ultrabase, segredos seguros, runtime automático, governança multiapp, backups e gates de aceitação reais.

Ele não é o serviço gerenciado Supabase Cloud e não pretende simular recursos de nuvem que não existem no self-hosting. Organização, infraestrutura, atualização, monitoramento, backup, disponibilidade e segurança operacional pertencem ao operador da instalação.

## Stack incluída

| Capacidade | Implementação |
|---|---|
| Banco relacional | PostgreSQL 17 com extensões |
| Autenticação | GoTrue, usuários, sessões, MFA/OAuth configuráveis, JWT ES256/JWKS |
| API REST | PostgREST com Row Level Security |
| GraphQL | `pg_graphql` pelo gateway |
| Tempo real | Supabase Realtime sobre replicação PostgreSQL |
| Arquivos | Storage API privada/pública com políticas RLS e transformação de imagem |
| Funções | Edge Runtime/Deno |
| Painel | Studio com identidade Ultrabase |
| Gateway | Kong, CORS, ACL e tradução de chaves opacas |
| Pool de conexões | Supavisor |
| Observabilidade | Logflare + Vector |
| Governança multiapp | Manifestos, namespace por app, migrations auditáveis e ledgers imutáveis |

Os nomes internos de alguns serviços e contêineres continuam contendo `supabase` para preservar compatibilidade técnica com o upstream. A plataforma exposta ao usuário é o Ultrabase.

## Executar no Windows

Pré-requisito principal: **Docker Desktop** em funcionamento. Node.js 22 é usado quando já está instalado; na ausência dele, o próprio Docker executa o gerador de configuração.

1. Baixe ou clone este repositório.
2. Dê dois cliques em **`RUN.bat`**.
3. O Studio abrirá em **`http://127.0.0.1:8000`**.

Opções disponíveis:

```text
RUN.bat
RUN.bat /sem-navegador
RUN.bat /sem-pull
RUN.bat /reinstalar
RUN.bat /parar
```

O `RUN.bat` é o único ponto de entrada humano. O bootstrap interno:

- preserva alterações locais durante o `git pull --ff-only`;
- inicia o Docker Desktop quando necessário;
- gera senhas, chaves opacas, JWTs legados e ES256/JWKS com criptografia real;
- recusa defaults inseguros;
- nunca substitui automaticamente credenciais de um banco já inicializado;
- valida o grafo Docker Compose antes de subir;
- instala o monitor automático, inicia os serviços e executa verificações reais;
- nunca apaga volumes de dados em uma reinstalação.

## Segurança local

A configuração padrão é deliberadamente local:

- portas administrativas e de banco publicadas somente em `127.0.0.1`;
- Studio sem prompt de Basic Auth somente dentro desse overlay loopback;
- cadastro anônimo e autenticação por telefone desligados por padrão;
- Functions exigindo JWT;
- `docker/.env`, banco vivo, Storage vivo e dumps bloqueados no Git;
- `.env` protegido por ACL no Windows e modo `0600` em sistemas POSIX;
- chaves secretas nunca escritas em relatórios de CI.

**Não publique diretamente as portas locais na internet.** Uma implantação externa exige domínio, TLS, proxy reverso, autenticação administrativa, SMTP/provedores configurados, firewall, rotação de segredos, monitoramento, estratégia de backup externo e recuperação testada.

## Um backend para vários aplicativos

O Ultrabase local usa uma única instalação física e separa aplicativos por manifesto, prefixo de tabelas, buckets, Functions, migrations e RLS. O controlador `ultrabase/runtime/Ultrabase-AppMigration.ps1` valida namespace, exige backup antes de mudanças pendentes, registra SHA-256 e mantém migration + ledger na mesma transação.

Consulte:

- [`ULTRABASE.md`](ULTRABASE.md)
- [`ULTRABASE-DOCUMENTACAO-UNIFICADA.md`](ULTRABASE-DOCUMENTACAO-UNIFICADA.md)
- [`ultrabase/runtime/APP-MIGRATIONS.md`](ultrabase/runtime/APP-MIGRATIONS.md)
- [`ultrabase/runtime/ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md`](ultrabase/runtime/ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md)

## Prova de funcionamento sem mocks

O workflow [`ULTRABASE Self-Hosted Acceptance`](.github/workflows/ultrabase-self-hosted-acceptance.yml) sobe a stack descartável real e só aprova quando comprova:

1. 13 serviços ativos e saudáveis, com portas limitadas ao loopback;
2. Studio e branding Ultrabase;
3. dois usuários reais e tokens de sessão ES256;
4. CRUD REST e bloqueios negativos de RLS entre usuários;
5. consulta GraphQL real;
6. entrega de um `INSERT` PostgreSQL pelo Realtime;
7. bucket privado, políticas Storage RLS e round-trip byte a byte;
8. rejeição de Function sem JWT e execução autenticada;
9. `pg_dump` em formato custom, leitura por `pg_restore` e restauração em banco temporário;
10. ausência de segredos ou dados vivos versionados.

O relatório gerado contém apenas nomes de testes, duração e estado; credenciais efêmeras não são publicadas.

## Atualizações e upstream

Este repositório deriva do projeto open source [Supabase](https://github.com/supabase/supabase) e mantém a licença Apache 2.0. Alterações Ultrabase e atribuições estão descritas em [`NOTICE`](NOTICE). O pin upstream e o estado auditável do runtime ficam em [`ULTRABASE-STATUS.json`](ULTRABASE-STATUS.json).

Supabase é marca de seus respectivos proprietários. Ultrabase não é afiliado, patrocinado nem suportado pela Supabase, Inc.
