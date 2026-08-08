# Ultrabase — manual mestre de uso e integração

Versão do manual: 1.0 · Base oficial verificada: Supabase `c0f1ef51fb9c083ab3a2e6867def0c4c7b2fa521` · Data da verificação: 3 de agosto de 2026

## 1. Resposta direta

O Ultrabase deve funcionar como a **plataforma de dados local compartilhada** dos aplicativos: um PostgreSQL central, acompanhado de autenticação, API automática, arquivos, tempo real, funções e painel visual. Os aplicativos não precisam implementar esses serviços do zero.

Para a instalação atual, o padrão é:

- o Ultrabase roda neste computador, sem mensalidade e sem depender da nuvem;
- o painel fica em `http://127.0.0.1:8000/project/default`;
- todos os serviços continuam privados ao próprio computador;
- frontends, aplicativos móveis e código entregue ao usuário usam a URL e a **chave publicável**;
- backends e robôs confiáveis podem usar uma credencial privilegiada, mas ela fica somente no ambiente protegido do processo;
- conexões PostgreSQL diretas são reservadas a backends controlados, migrations, administração, relatórios e backup;
- toda tabela acessível pela API precisa de Row Level Security (RLS);
- cada mudança de estrutura deve virar uma migration SQL versionada;
- backup precisa incluir banco, arquivos do Storage, Functions e configuração secreta guardada separadamente.

O sistema local já está pronto e saudável. Este documento define como usá-lo sem transformar a facilidade do ambiente local em uma falha de segurança quando mais aplicativos forem conectados.

## 2. O que existe dentro do Ultrabase

| Componente | Para que serve | Como os apps normalmente usam |
|---|---|---|
| PostgreSQL | Fonte da verdade para dados relacionais, regras, índices e transações | API de dados ou conexão SQL em backend confiável |
| Studio | Painel visual/no-code | Pessoas administradoras criam e inspecionam estruturas e dados |
| Auth | Cadastro, login, sessões e tokens JWT | SDK do Supabase no app |
| PostgREST | API REST criada automaticamente a partir do banco | SDK, HTTP ou ferramenta de automação |
| Realtime | Eventos de banco, Broadcast e Presence | WebSocket por meio do SDK |
| Storage | Buckets e arquivos | SDK ou API HTTP, sempre com políticas de acesso |
| Edge Functions | Endpoints TypeScript/Deno e integrações protegidas | `/functions/v1/<nome>` |
| Supavisor | Pool de conexões PostgreSQL | Porta 5432 para sessão; 6543 para transação |
| Kong | Entrada única das APIs | URL base `http://127.0.0.1:8000` |
| Logflare + Vector | Logs e Analytics locais | Consulta no Studio e diagnóstico operacional |

Fluxo principal:

```text
App web, desktop, mobile ou automação
                 |
                 | URL + chave publicável + sessão do usuário
                 v
        Ultrabase / Kong :8000
          |       |       |
        Auth    REST    Storage / Realtime / Functions
          \       |       /
                  v
             PostgreSQL 17
                  ^
                  |
      backend confiável / migration / backup
        sessão :5432 ou transação :6543
```

O self-hosted representa **um projeto Supabase único**. Isso significa um banco principal, um conjunto global de usuários do Auth e uma configuração comum de serviços. Não há, nessa instalação, organizações e projetos independentes como no painel comercial.

## 3. Regra de escolha: como cada tipo de consumidor se conecta

Esta é a tabela mais importante do manual.

| Consumidor | Conexão recomendada | Credencial | Motivo |
|---|---|---|---|
| Navegador web | SDK/Data API | chave publicável + sessão do usuário | A RLS protege cada linha |
| App mobile | SDK/Data API | chave publicável + sessão do usuário | Nenhum segredo fica dentro do APK/IPA |
| App desktop distribuído | SDK/Data API | chave publicável + sessão do usuário | Binários podem ser inspecionados; segredo seria vazado |
| Frontend local em `localhost` | SDK/Data API | chave publicável + sessão do usuário | Mesmo padrão de produção e teste mais realista |
| Backend persistente | SDK/Data API ou PostgreSQL em modo sessão | segredo somente no servidor ou role SQL limitada | Controle de acesso e desempenho, conforme a necessidade |
| Worker/RPA contínuo | API com usuário técnico ou PostgreSQL em modo sessão | sessão restrita, segredo no cofre ou role limitada | Processo duradouro e auditável |
| Job curto/serverless | Data API ou PostgreSQL em modo transação | segredo no ambiente protegido | Pool adequado para conexões breves |
| Migration, `pg_dump`, BI administrativo | PostgreSQL em modo sessão | senha do banco ou role administrativa | Precisa de recursos nativos do PostgreSQL |
| Integração externa/webhook | Edge Function | autenticação do chamador e segredos no servidor | Evita expor segredo e concentra validação |

### Nunca faça isto

- nunca coloque `SUPABASE_SECRET_KEY`, `SERVICE_ROLE_KEY` ou `POSTGRES_PASSWORD` em JavaScript do navegador;
- nunca embuta esses segredos em app mobile ou desktop distribuído;
- nunca conecte um frontend diretamente à porta PostgreSQL;
- nunca desligue RLS para “fazer a API funcionar”;
- nunca exponha a instalação atual trocando `127.0.0.1` por `0.0.0.0` sem HTTPS, firewall, autenticação do painel e revisão completa de segurança;
- nunca trate um dump do banco como backup dos arquivos do Storage — o dump contém metadados, não os arquivos em si.

## 4. Endereços da instalação local

| Recurso | Endereço local |
|---|---|
| Painel Ultrabase | `http://127.0.0.1:8000/project/default` |
| URL base dos SDKs | `http://127.0.0.1:8000` |
| Auth HTTP | `http://127.0.0.1:8000/auth/v1` |
| API REST | `http://127.0.0.1:8000/rest/v1` |
| GraphQL | `http://127.0.0.1:8000/graphql/v1` |
| Storage | `http://127.0.0.1:8000/storage/v1` |
| Realtime | `http://127.0.0.1:8000/realtime/v1` |
| Edge Function | `http://127.0.0.1:8000/functions/v1/<nome>` |
| PostgreSQL/Supavisor sessão | `127.0.0.1:5432` |
| PostgreSQL/Supavisor transação | `127.0.0.1:6543` |

`127.0.0.1` sempre significa “este mesmo computador”. Um celular, outra máquina ou um contêiner separado não encontra o Ultrabase usando esse endereço. Para outro dispositivo, use uma VPN privada ou faça uma publicação segura com domínio, HTTPS, firewall e painel protegido.

## 5. Configuração mínima de qualquer aplicativo

O arquivo-modelo pronto está em [`../APPS-CONEXAO.env.example`](../APPS-CONEXAO.env.example).

```dotenv
SUPABASE_URL=http://127.0.0.1:8000
SUPABASE_PUBLISHABLE_KEY=COLE_AQUI_A_CHAVE_PUBLICAVEL
```

A chave publicável real pode ser consultada dando duplo clique em `ultrabase/03-MOSTRAR-CREDENCIAIS.cmd`. Ela pode aparecer no código cliente porque identifica o projeto; a proteção dos dados vem da sessão do usuário, dos grants e da RLS.

Se o framework exige nomes públicos, faça apenas um mapeamento:

```dotenv
# Vite
VITE_SUPABASE_URL=http://127.0.0.1:8000
VITE_SUPABASE_PUBLISHABLE_KEY=COLE_AQUI

# Next.js
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:8000
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=COLE_AQUI
```

Não renomeie uma chave secreta para `NEXT_PUBLIC_*` ou `VITE_*`: esses prefixos publicam o valor no navegador.

### JavaScript/TypeScript

```bash
npm install @supabase/supabase-js
```

```ts
import { createClient } from '@supabase/supabase-js'

export const ultrabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
)
```

Consulta protegida pela sessão e pela RLS:

```ts
const { data, error } = await ultrabase
  .from('app_exemplo_tarefas')
  .select('id,titulo,concluida,created_at')
  .order('created_at', { ascending: false })
```

### Python

```bash
pip install supabase
```

```python
import os
from supabase import create_client

ultrabase = create_client(
    os.environ["SUPABASE_URL"],
    os.environ["SUPABASE_PUBLISHABLE_KEY"],
)
```

### HTTP puro, n8n, Power Automate ou outra ferramenta de automação

```http
GET http://127.0.0.1:8000/rest/v1/app_exemplo_tarefas?select=id,titulo
apikey: <CHAVE_PUBLICAVEL>
Authorization: Bearer <TOKEN_DA_SESSAO_DO_USUARIO>
```

Quando não existe usuário conectado, a requisição assume o papel anônimo. Ela só deve ler ou alterar o que uma política explícita para `anon` permitir. Para a maioria dos dados internos, não crie políticas anônimas.

## 6. Como organizar muitos aplicativos no mesmo Ultrabase

Há três modelos possíveis.

### Modelo A — tabelas no `public` com prefixo por app

Exemplos: `crm_contatos`, `crm_negocios`, `erp_pedidos`, `rpa_execucoes`.

É o melhor começo para poucos aplicativos porque a Data API já expõe o schema `public`. Cada tabela continua isolada por grants e políticas RLS. O prefixo evita colisões e facilita inventário e backup.

### Modelo B — schema PostgreSQL por app

Exemplos: `crm.contatos`, `erp.pedidos`, `automacao.execucoes`.

É melhor para bancos grandes e responsabilidades claramente separadas. Um schema não fica disponível na Data API só por existir: ele precisa ser incluído conscientemente nos schemas expostos do PostgREST e receber grants e políticas corretas. Use esse modelo principalmente para acesso interno via backend ou quando a equipe já administra Postgres com segurança.

### Modelo C — uma instância Ultrabase por domínio de segurança

Use instâncias separadas quando aplicativos pertencem a clientes diferentes, têm requisitos de retenção incompatíveis, administradores distintos ou quando um comprometimento não pode alcançar os demais dados. É o isolamento mais forte, ao custo de mais memória, atualizações e backups.

### Recomendação prática atual

Comece com o Modelo A e adote estas convenções:

| Item | Convenção |
|---|---|
| Tabelas | `<app>_<entidade>`, em minúsculas |
| Coluna de dono | `owner_id uuid references auth.users(id)` |
| Chave primária | `id uuid default gen_random_uuid()` |
| Datas | `created_at` e `updated_at` em `timestamptz` |
| Exclusão lógica | `deleted_at timestamptz`, se o produto precisar de auditoria |
| Migrações | uma pasta versionada no repositório de cada app |
| Arquivos | bucket privado por app ou por finalidade |
| Eventos RPA | tabela de jobs com chave de idempotência |

O Auth é compartilhado: uma pessoa tem uma identidade global em `auth.users` dentro deste Ultrabase. Perfil, organização, permissões por app e associação a clientes devem ficar em tabelas próprias. Não edite `auth.users` diretamente; use a API administrativa do Auth em backend confiável.

## 7. Modelo seguro de tabela para um app

O exemplo abaixo pode ser executado no SQL Editor. Ele cria uma tabela acessível apenas pelo dono autenticado.

```sql
create table public.app_exemplo_tarefas (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid()
    references auth.users(id) on delete cascade,
  titulo text not null check (char_length(titulo) between 1 and 300),
  concluida boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.app_exemplo_tarefas enable row level security;

revoke all on table public.app_exemplo_tarefas from anon;
grant select, insert, update, delete
  on table public.app_exemplo_tarefas to authenticated;

create policy "tarefas: dono pode ler"
on public.app_exemplo_tarefas
for select to authenticated
using ((select auth.uid()) = owner_id);

create policy "tarefas: dono pode criar"
on public.app_exemplo_tarefas
for insert to authenticated
with check ((select auth.uid()) = owner_id);

create policy "tarefas: dono pode alterar"
on public.app_exemplo_tarefas
for update to authenticated
using ((select auth.uid()) = owner_id)
with check ((select auth.uid()) = owner_id);

create policy "tarefas: dono pode excluir"
on public.app_exemplo_tarefas
for delete to authenticated
using ((select auth.uid()) = owner_id);
```

Checklist para cada tabela exposta:

- RLS está habilitada;
- `anon` não recebeu acesso por acidente;
- cada operação necessária tem sua própria política;
- `UPDATE` usa tanto `USING` quanto `WITH CHECK`;
- a política foi testada com dois usuários diferentes;
- colunas sensíveis não são retornadas por `select('*')` sem necessidade;
- índices existem nas colunas usadas pelas políticas, como `owner_id` e `organization_id`.

Uma chave publicável **não contorna RLS**. Uma chave secreta/service role pode contornar; por isso ela nunca deve ser usada para testar se as políticas de um app estão corretas.

## 8. Autenticação e perfis

O SDK administra cadastro, login, renovação de sessão e envio do JWT às outras APIs. A autenticação responde “quem é”; a RLS responde “o que essa identidade pode fazer”.

Padrão recomendado:

1. o app chama `signUp` ou `signInWithPassword` pelo SDK;
2. o Auth devolve uma sessão;
3. o SDK renova e envia o token automaticamente;
4. o PostgreSQL lê `auth.uid()` dentro das políticas;
5. dados adicionais ficam em uma tabela como `public.perfis`, ligada a `auth.users(id)`.

No ambiente local atual, e-mail é autoconfirmado para não exigir um serviço SMTP pago. Isso é conveniente para desenvolvimento, mas não deve permanecer em uma publicação real. Em rede ou produção:

- configure SMTP;
- desative autoconfirmação;
- configure `SITE_URL` e a lista exata de redirecionamentos;
- use HTTPS para login, OAuth e recuperação de senha;
- revise tempo de sessão, MFA e provedores externos;
- proteja ações administrativas em backend confiável.

Como há um Auth comum, use tabelas de associação para autorização por aplicativo:

```text
auth.users
    |
    +-- app_membros (user_id, app_id, papel, ativo)
    +-- organizacoes_membros (user_id, organization_id, papel)
```

As políticas RLS consultam essas associações em vez de confiar em um papel enviado livremente pelo cliente.

## 9. Backend confiável e acesso administrativo

Há dois padrões válidos.

### Backend pela Data API

Use o SDK com chave publicável e token do usuário quando o backend deve obedecer às mesmas políticas do usuário. Use uma chave secreta somente para uma operação administrativa explícita.

Vantagens:

- mesma autenticação e autorização dos apps;
- menor acoplamento ao driver PostgreSQL;
- chamadas simples a Auth, Storage, Functions e banco;
- menor risco de abrir acesso SQL amplo.

### Backend por PostgreSQL

Use quando precisa de transações complexas, alto volume, ORM, SQL avançado, BI, migrations ou backup.

Modo sessão, para backend persistente e ferramentas administrativas:

```text
postgres://postgres.<POOLER_TENANT_ID>:<POSTGRES_PASSWORD>@127.0.0.1:5432/postgres
```

Modo transação, para processos breves ou que escalam rapidamente:

```text
postgres://postgres.<POOLER_TENANT_ID>:<POSTGRES_PASSWORD>@127.0.0.1:6543/postgres
```

O modo transação não suporta prepared statements; desative-os no driver quando usar a porta 6543. Não copie a senha real para documentação, logs ou repositórios. Obtenha `POOLER_TENANT_ID` e a senha do ambiente protegido da instalação.

Para aplicações comuns, não use o superusuário `postgres` em tempo de execução. Crie uma role limitada ao schema/tabelas necessários e mantenha uma pool pequena. A senha administrativa permanece reservada a manutenção.

## 10. RPA, agentes, robôs e tarefas automáticas

Um RPA deve ser tratado como um backend, não como um frontend invisível.

Ordem de preferência:

1. **usuário técnico do Auth + RLS:** melhor quando o robô deve ter acesso semelhante a uma pessoa ou equipe;
2. **Edge Function protegida:** melhor quando o robô dispara uma ação bem definida, como importar um arquivo ou sincronizar pedidos;
3. **role PostgreSQL limitada:** melhor para worker interno de alto volume;
4. **chave secreta/service role:** somente quando é realmente necessário atravessar políticas; restrinja o processo e registre todas as ações.

Estrutura mínima de jobs:

```sql
create table public.rpa_jobs (
  id uuid primary key default gen_random_uuid(),
  app text not null,
  tipo text not null,
  idempotency_key text not null unique,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pendente'
    check (status in ('pendente', 'executando', 'concluido', 'falhou')),
  tentativas integer not null default 0,
  erro text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);
```

Regras para automações:

- use `idempotency_key` para uma repetição não criar efeitos duplicados;
- grave início, fim, resultado e erro;
- limite tentativas e aplique atraso progressivo;
- não coloque senhas dentro de `payload`;
- mantenha segredos em variáveis de ambiente/cofre;
- use transação ao atualizar negócio + status do job;
- um robô por cliente/app deve receber apenas o escopo de que precisa;
- jobs longos não devem ocupar uma Edge Function indefinidamente; use worker de fundo.

Para n8n, Make, Power Automate ou scripts, prefira a REST API. Para um worker Python/Node duradouro, escolha Data API ou porta 5432. Para invocações curtas e numerosas com SQL, use 6543 e desative prepared statements.

## 11. Storage: documentos, imagens e anexos

O Storage guarda o arquivo no volume local e registra metadados no schema `storage`. Buckets privados devem ser o padrão; bucket público só é apropriado para conteúdo realmente público, como logotipo ou catálogo aberto.

As permissões são políticas RLS em `storage.objects`:

- `INSERT` controla upload;
- `SELECT` controla listagem/leitura autenticada;
- `UPDATE` é necessário para substituir;
- `DELETE` controla exclusão.

Organize caminhos previsíveis:

```text
<app>/<user_id>/<categoria>/<arquivo>
```

Isso facilita políticas por dono e migração. Não altere diretamente as tabelas do schema `storage`; use o SDK/API para mover e excluir objetos, mantendo arquivo e metadados consistentes.

A chave secreta contorna as políticas do Storage. Ela só pode estar em servidor/worker confiável. O backup do banco não inclui o conteúdo físico dos buckets, então sempre execute também o backup do Storage.

## 12. Realtime

Use Realtime quando a interface realmente precisa receber mudanças sem recarregar: chat, painel vivo, presença, alertas e colaboração.

Opções:

- **Broadcast:** recomendado para melhor escalabilidade e controle em recursos colaborativos;
- **Presence:** estado temporário de quem está conectado;
- **Postgres Changes:** simples para começar, mas precisa adicionar a tabela à publicação `supabase_realtime` e tende a escalar menos que Broadcast.

Para Postgres Changes:

```sql
alter publication supabase_realtime
add table public.app_exemplo_tarefas;
```

Não habilite todas as tabelas “por garantia”. Publique somente o necessário, mantenha RLS e use filtros no cliente. Eventos não substituem uma consulta de confirmação nem uma fila durável; uma desconexão pode exigir sincronização posterior.

## 13. Edge Functions

Use Edge Functions para:

- receber webhooks;
- chamar APIs externas sem expor segredos;
- validar uma ação composta;
- enviar e-mails;
- entregar um endpoint específico para RPA;
- executar lógica curta próxima dos serviços do Ultrabase.

Na instalação self-hosted, as funções ficam em `docker/volumes/functions/<nome>/index.ts` e são chamadas em:

```text
http://127.0.0.1:8000/functions/v1/<nome>
```

Dentro da rede Docker, a função usa `SUPABASE_URL=http://kong:8000` para falar com os serviços. Para construir um link que o cliente externo abrirá, usa `SUPABASE_PUBLIC_URL`.

Segredos personalizados devem ficar em arquivo de ambiente ignorado pelo Git e ser fornecidos ao serviço `functions`. Nunca escreva segredo no código. Mantenha verificação de JWT ligada por padrão; webhooks públicos precisam validar assinatura própria do provedor e ter proteção contra repetição.

Funções devem ser curtas e idempotentes. Processamento pesado, filas longas e tarefas de vários minutos pertencem a um worker.

## 14. No-code no Studio e migrations

O Studio é ideal para:

- explorar tabelas e relacionamentos;
- montar uma primeira política;
- testar SQL;
- criar usuários de desenvolvimento;
- gerenciar buckets;
- inspecionar API e logs.

Porém, o estado final do banco não pode existir apenas “na tela”. Depois de aprovar uma alteração, salve SQL em uma migration versionada.

Estrutura recomendada no repositório de cada app:

```text
supabase/
  migrations/
    20260803090000_cria_app_tarefas.sql
    20260803100000_adiciona_prioridade.sql
  seed.sql
```

Regras:

- uma migration aplicada nunca é reescrita; crie outra para corrigir;
- schema e políticas vão em migrations;
- `seed.sql` contém somente dados reproduzíveis de desenvolvimento, não estrutura;
- segredos e dados pessoais nunca entram em seed;
- teste migrations numa instância vazia ou cópia antes de aplicar ao banco principal;
- faça backup antes de alteração destrutiva;
- cada app é responsável pelos nomes que possui.

O Supabase CLI pode gerar migration, diff, tipos TypeScript e seeds. Ele é uma ferramenta de desenvolvimento; não substitui o Ultrabase self-hosted em execução.

## 15. Backup, restauração e continuidade

Dê duplo clique em `ultrabase/05-FAZER-BACKUP.cmd`. O pacote operacional inclui:

- dump lógico do PostgreSQL;
- roles;
- ZIP do conteúdo físico do Storage;
- manifesto;
- Functions internas.

Também guarde, separadamente e de forma criptografada:

- `docker/.env` e outros arquivos de segredos;
- códigos das Functions;
- migrations de cada app;
- versão das imagens/commit do Ultrabase;
- configuração de domínio, SMTP, OAuth e reverse proxy, se existirem.

Política mínima recomendada:

| Frequência | Ação |
|---|---|
| Antes de migration/atualização | backup completo imediato |
| Diário, se os dados importam | backup automatizado |
| Semanal | cópia criptografada em outro disco/máquina |
| Mensal | teste de restauração em instância vazia |

Um backup que nunca foi restaurado é apenas uma esperança. Valide o catálogo do dump, abra o ZIP do Storage e faça periodicamente uma restauração completa fora da instância ativa.

O arquivo oficial `docker/reset.sh` apaga banco e Storage. Ele não faz parte da operação normal.

## 16. Migração para nuvem ou outro banco

### Outro Ultrabase ou Supabase

É o caminho mais próximo. Migre separadamente:

- schema, funções, roles e dados PostgreSQL;
- objetos do Storage;
- Edge Functions;
- secrets;
- configurações de Auth, SMTP, OAuth e URLs;
- chaves de assinatura/sessões, conforme a estratégia de segurança.

### PostgreSQL comum, Neon, RDS ou servidor próprio

Tabelas, índices, views, funções e dados compatíveis viajam com ferramentas PostgreSQL. Auth, Storage, Realtime e Edge Functions são serviços adicionais: o destino precisa mantê-los ou substituí-los.

### MySQL, SQL Server, SQLite ou MongoDB

Não existe restauração direta. Tipos, policies RLS, funções, triggers, extensões e consultas precisam ser convertidos. Migrations versionadas e uma camada de acesso a dados bem definida reduzem o acoplamento.

## 17. Local, rede privada e produção

| Cenário | Configuração adequada |
|---|---|
| Desenvolvimento neste PC | configuração atual em `127.0.0.1`, autoconfirmação local, painel automático |
| Apps em outros PCs da casa/empresa | VPN privada, firewall, endereço alcançável, painel novamente autenticado |
| Produção na internet | domínio, HTTPS, reverse proxy, firewall, SMTP, Auth revisado, backups externos, alertas e plano de atualização |

Antes de publicar:

- remova o acesso automático local ao Studio;
- gere/rote todos os segredos de produção;
- use chaves modernas publicáveis/secretas e proteja a chave secreta;
- configure HTTPS e cabeçalhos de proxy corretamente;
- restrinja portas PostgreSQL; de preferência, não as publique na internet;
- configure SMTP, URLs e callbacks OAuth;
- desligue autoconfirmação de e-mail;
- faça teste de RLS como `anon`, usuário A, usuário B e backend;
- configure limite de recursos, monitoramento, backup externo e restauração;
- faça atualização controlada com rollback.

Self-hosting transfere para o proprietário a responsabilidade por patches, disponibilidade, segurança do sistema operacional, banco, alta disponibilidade e recuperação de desastre. O software não envia telemetria à Supabase, mas logs e dados continuam sob sua própria responsabilidade.

## 18. Runtime automático compartilhado

O computador usa uma única instalação Ultrabase para todos os apps. O runtime instalado no início do Windows:

- chama o Docker Desktop somente quando necessário;
- mantém um monitor oculto e único;
- recupera a stack quando ela fica indisponível inesperadamente;
- respeita a pausa persistente criada por `08-PARAR-SEM-APAGAR.cmd`;
- gera o contrato público dos apps em `%LOCALAPPDATA%\Ultrabase`;
- não entrega senha PostgreSQL, service role, chave secreta ou credencial do painel.

Arquivos de descoberta:

```text
C:\Users\lucas\AppData\Local\Ultrabase\connection.json
C:\Users\lucas\AppData\Local\Ultrabase\connection.env
C:\Users\lucas\AppData\Local\Ultrabase\runtime-status.json
```

Antes de conectar, o app executa:

```text
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\ultrabase\runtime\Ultrabase-Runtime.ps1" -Action ensure -Json
```

Com código 0 e `ready: true`, usa `url` e `publishable_key` do contrato. Código 2 indica pausa consciente: o app deve informar o usuário e não forçar o retorno. Backend em outro container usa `http://host.docker.internal:8000`; chamadas do navegador continuam em `http://127.0.0.1:8000`.

Se o app realmente precisa receber comandos offline, ele mantém uma outbox SQLite local, com UUID, idempotência, tentativas e regra de conflito, e sincroniza depois. Nunca escreve diretamente nos volumes Docker.

Instalação/reparo: `09-INSTALAR-RUNTIME-AUTOMATICO.cmd`. Validação: `10-TESTAR-RUNTIME-DOS-APPS.cmd`. Remoção reversível do autostart: `11-REMOVER-INICIO-AUTOMATICO.cmd`.

## 19. Checklist para conectar um novo app

1. Escolha um identificador curto, por exemplo `crm`.
2. Decida se o app compartilha o Auth atual; se o limite de segurança for diferente, crie outra instância.
3. Crie migrations com tabelas prefixadas, chaves, constraints e índices.
4. Habilite RLS em toda tabela exposta.
5. Escreva policies por operação e por dono/organização.
6. Crie bucket privado e policies, se houver arquivos.
7. Copie URL e chave publicável para o `.env` local do app.
8. Implemente Auth pelo SDK.
9. Teste com dois usuários e confirme que um não vê dados do outro.
10. Se houver backend/RPA, escolha usuário técnico, Function ou role limitada; evite service role por padrão.
11. Adicione as tabelas estritamente necessárias ao Realtime.
12. Versione migrations, tipos e código; não versione segredos.
13. Execute a validação do Ultrabase.
14. Faça backup antes de carregar dados importantes.
15. Registre dono, finalidade, retenção e procedimento de restauração do app.

## 20. Checklist de diagnóstico

| Sintoma | Verificação |
|---|---|
| App não conecta | Ultrabase iniciado, URL correta e app no mesmo computador |
| HTTP 401 | chave ausente/incorreta ou JWT inválido/expirado |
| HTTP 403/RLS | grants e policy da operação, usuário e `auth.uid()` |
| Lista vazia sem erro | RLS está filtrando; teste a policy com a identidade correta |
| Celular não conecta | `127.0.0.1` aponta para o próprio celular, não para o PC |
| Upload falha | bucket, tamanho/MIME, policy `INSERT` em `storage.objects` |
| Upsert de arquivo falha | também precisa de `SELECT` e `UPDATE` |
| Realtime não recebe | tabela/publicação, evento, RLS, filtro e conexão WebSocket |
| SQL na 6543 falha | prepared statements devem estar desligados em modo transação |
| E-mail não chega | o local autoconfirma; produção requer SMTP correto |
| Function retorna 401 | JWT/`apikey`, verificação da função e segredo correto |
| Banco voltou mas arquivos sumiram | restaure também o ZIP físico do Storage |

Use `ultrabase/04-VALIDAR-TUDO.cmd` para checar todos os serviços e `ultrabase/06-VER-LOGS.cmd` para diagnóstico.

## 21. Documentação oficial offline e referências

O fork contém a cópia completa e versionada da documentação oficial em:

```text
apps/docs/content/
```

São 813 arquivos-fonte, incluindo 812 documentos MDX. O inventário individual e os hashes estão em [`INVENTARIO-DOCUMENTACAO-OFICIAL.csv`](./INVENTARIO-DOCUMENTACAO-OFICIAL.csv). O ZIP navegável sem internet e seu hash ficam descritos no [`MANIFESTO-DOCUMENTACAO.json`](./MANIFESTO-DOCUMENTACAO.json).

Leituras oficiais centrais:

- [Self-hosting](../../apps/docs/content/guides/self-hosting.mdx)
- [Self-hosting com Docker](../../apps/docs/content/guides/self-hosting/docker.mdx)
- [Chaves da API](../../apps/docs/content/guides/getting-started/api-keys.mdx)
- [Conexões PostgreSQL](../../apps/docs/content/guides/database/connecting-to-postgres.mdx)
- [Row Level Security](../../apps/docs/content/guides/database/postgres/row-level-security.mdx)
- [Arquitetura do Auth](../../apps/docs/content/guides/auth/architecture.mdx)
- [Políticas do Storage](../../apps/docs/content/guides/storage/security/access-control.mdx)
- [Realtime / Postgres Changes](../../apps/docs/content/guides/realtime/postgres-changes.mdx)
- [Functions self-hosted](../../apps/docs/content/guides/self-hosting/self-hosted-functions.mdx)
- [Migrations](../../apps/docs/content/guides/deployment/database-migrations.mdx)
- [Seeds](../../apps/docs/content/guides/local-development/seeding-your-database.mdx)
- [Restauração para self-hosted](../../apps/docs/content/guides/self-hosting/restore-from-platform.mdx)

Este manual é a orientação operacional do Ultrabase. Quando uma opção técnica avançada não estiver coberta aqui, consulte primeiro a fonte offline correspondente ao mesmo snapshot; depois confira a documentação online para mudanças posteriores.
