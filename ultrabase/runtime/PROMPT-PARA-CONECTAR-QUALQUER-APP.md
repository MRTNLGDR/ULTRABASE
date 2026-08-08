# Prompt definitivo — conectar qualquer app ao Ultrabase

Copie todo o conteúdo a partir da linha “INÍCIO DO PROMPT” e cole numa tarefa aberta na raiz do aplicativo.

---

## INÍCIO DO PROMPT

Integre o aplicativo aberto nesta tarefa ao **Ultrabase Local Runtime** já instalado neste computador. Execute a integração e, se existir banco anterior, faça a migração segura e validada. Não entregue somente um plano.

### Ultrabase já instalado

```text
Raiz: D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase
URL de navegador/Windows: http://127.0.0.1:8000
Painel: http://127.0.0.1:8000/project/default
Controlador: D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\ultrabase\runtime\Ultrabase-Runtime.ps1
Contrato público: C:\Users\lucas\AppData\Local\Ultrabase\connection.json
Configuração pública .env: C:\Users\lucas\AppData\Local\Ultrabase\connection.env
Status: C:\Users\lucas\AppData\Local\Ultrabase\runtime-status.json
Manual: D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\ultrabase\documentacao\ULTRABASE-MANUAL-MESTRE.md
Runtime: D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\ultrabase\runtime\README.md
Arquitetura multiapp: D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\ultrabase\runtime\ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md
```

O Ultrabase é único e compartilhado por todos os apps deste computador. Não instale outra cópia, não crie outra stack Docker e não empacote um banco Ultrabase separado dentro deste aplicativo.

Antes de alterar banco, Storage, Realtime ou Functions, leia integralmente `ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md` e cumpra o padrão de namespace. Há um projeto físico e um banco físico; este app recebe um domínio lógico exclusivo.

### Namespace obrigatório do aplicativo

1. inspecione os prefixos já usados em tabelas, views, RPCs, buckets, Edge Functions e migrations;
2. escolha um `app_slug` exclusivo, imutável, em minúsculas e com 2 a 24 caracteres;
3. crie e versione `ultrabase.app.json` na raiz deste app conforme o modelo do documento de arquitetura;
4. use `<app_slug>_` em tabelas, views e funções SQL;
5. use `<app-slug>-` em buckets e Edge Functions e `<app_slug>:` em canais Realtime;
6. inclua o slug no nome de toda migration;
7. não leia nem escreva diretamente em objetos pertencentes ao prefixo de outro app;
8. use `core_` somente para recurso realmente compartilhado, com contrato e autorização explícitos;
9. registre dependências compartilhadas em `ultrabase.app.json`;
10. não declare que uma tabela, bucket ou função existe sem verificar no Ultrabase.

Auth pode compartilhar `auth.users`, mas o perfil, as associações e as policies específicas pertencem ao namespace deste app. Compartilhar login não significa compartilhar autorização ou dados.

### Descoberta e inicialização obrigatórias

Ao iniciar o aplicativo, execute de forma oculta e com timeout o comando equivalente a:

```text
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\ultrabase\runtime\Ultrabase-Runtime.ps1" -Action ensure -Json
```

Interprete o JSON e o código de saída:

- código `0` e `ready: true`: leia `C:\Users\lucas\AppData\Local\Ultrabase\connection.json` e conecte;
- código `2` ou `paused: true`: o proprietário pausou o Ultrabase; não force a retomada e mostre orientação clara;
- outro erro: não tente escrever nos volumes; mostre diagnóstico e mantenha os dados locais pendentes, se o app tiver modo offline.

Também é possível descobrir o contrato pelas variáveis de usuário:

```text
ULTRABASE_HOME
ULTRABASE_URL
ULTRABASE_CONNECTION_FILE
ULTRABASE_ENV_FILE
```

Não copie a chave publicável para código-fonte. Leia-a em tempo de execução do contrato ou copie `connection.env` para um `.env.local` ignorado pelo Git.

### Endereço conforme o processo

- navegador ou processo executado diretamente no Windows: `http://127.0.0.1:8000`;
- backend dentro de outro container Docker deste computador: `http://host.docker.internal:8000`;
- navegador servido por um container continua usando `http://127.0.0.1:8000`, porque a chamada parte do navegador;
- não publique `127.0.0.1` como URL de produção.

### Segurança obrigatória

Frontend, mobile e desktop distribuído podem usar somente:

```text
url
publishable_key
```

Nunca coloque no cliente, no Git, em logs ou na resposta:

```text
SUPABASE_SECRET_KEY
SUPABASE_SERVICE_ROLE_KEY
SERVICE_ROLE_KEY
POSTGRES_PASSWORD
JWT_SECRET
DASHBOARD_PASSWORD
```

Nunca leia ou escreva diretamente:

```text
D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\docker\volumes\db\data
D:\AIIA\01-apps-canonicos\25-Aiia-ultrabase\docker\volumes\storage
```

Clientes usam SDK/Data API, sessão do usuário e Row Level Security. Apenas backend confiável pode usar conexão PostgreSQL, sempre com credencial limitada e protegida.

### Inspeção do aplicativo

Descubra automaticamente:

1. raiz, nome, linguagem e framework do app;
2. banco atual, ORM, models, migrations, seeds e consultas;
3. tabelas, colunas, tipos, índices, constraints e relacionamentos;
4. quantidade de registros por tabela;
5. autenticação, usuários e perfis;
6. arquivos, imagens e anexos;
7. Realtime, jobs, RPA, filas e integrações;
8. todos os pontos do código que leem ou escrevem dados.

Escolha o `app_slug` conforme a arquitetura, prove que não colide e registre a decisão em `ultrabase.app.json`.

### Migração do banco anterior

Se já existir banco:

1. faça backup antes de alterar qualquer coisa;
2. registre contagens por tabela;
3. não apague, renomeie ou sobrescreva a origem;
4. crie rollback funcional;
5. crie migrations SQL versionadas em `supabase/migrations`;
6. prefira tabelas em `public` com prefixo do app;
7. não altere schemas internos `auth`, `storage`, `realtime`, `extensions` ou `supabase_functions`;
8. aplique estrutura, índices, constraints e policies por migrations;
9. migre dados respeitando tipos, IDs e chaves estrangeiras;
10. compare contagens e procure órfãos, nulos inesperados e falhas de conversão;
11. preserve o banco anterior até aprovação explícita.

Se o aplicativo não tiver banco anterior, crie a modelagem diretamente por migrations e não invente dados reais.

### RLS obrigatória

Para toda tabela exposta:

1. habilite RLS;
2. conceda somente os grants necessários;
3. crie policies separadas para `SELECT`, `INSERT`, `UPDATE` e `DELETE`;
4. use `USING` e `WITH CHECK` em atualizações;
5. use `owner_id`/`user_id` ligado a `auth.users(id)` quando houver dono;
6. crie associação de membros quando o acesso for por organização;
7. indexe colunas usadas pelas policies;
8. teste como anônimo, usuário A, usuário B e backend;
9. prove que A não vê ou altera dados privados de B;
10. não teste segurança usando service role.

### Auth, Storage, Realtime e Functions

- use Supabase Auth para sessão e identidade;
- nunca migre senha em texto puro nem invente senha;
- use tabela de perfil ligada a `auth.users(id)` quando necessário;
- use bucket privado e policies em `storage.objects` para arquivos;
- migre arquivos físicos separadamente do dump do banco;
- habilite Realtime apenas nas tabelas necessárias;
- use Edge Function para webhook ou integração que precisa de segredo;
- jobs longos pertencem a worker, não a Function mantida aberta indefinidamente.

### RPA e automações

Prefira, nesta ordem:

1. usuário técnico do Auth com RLS;
2. Edge Function protegida;
3. role PostgreSQL limitada;
4. chave administrativa somente quando indispensável.

Implemente idempotência, status, tentativas, atraso, início, fim, erro e auditoria. Não grave segredo no payload.

### Modo offline do aplicativo

O Ultrabase não recebe gravações quando estiver parado. Se este app precisa continuar operando offline, implemente uma **outbox SQLite local**:

1. grave localmente a operação pendente com UUID e chave de idempotência;
2. registre criação, tentativas, erro e estado de sincronização;
3. nunca guarde senha administrativa na fila;
4. sincronize quando `ensure` voltar com `ready: true`;
5. use upsert/RPC/transação idempotente para não duplicar efeitos;
6. marque como concluído somente após confirmação do Ultrabase;
7. defina e teste conflito quando o registro local e remoto mudarem;
8. não use a outbox se o app não precisa funcionar offline.

### Alteração do aplicativo

1. reutilize o SDK oficial compatível com a linguagem;
2. centralize o cliente Ultrabase em um módulo;
3. leia URL/chave do contrato ou ambiente, nunca de literal no código;
4. trate indisponibilidade e pausa sem travar a interface;
5. não inicie outro Docker se o monitor central já estiver ativo;
6. não espalhe acesso direto ao banco;
7. mantenha migrations como fonte do schema;
8. gere tipos quando aplicável;
9. atualize testes e documentação do app;
10. preserve configuração do banco anterior para rollback até o aceite.

### Preparação para subir online

Deixe configuração separada por ambiente. Uma migração futura deve trocar o contrato local por variáveis de produção, por exemplo:

```text
SUPABASE_URL=https://<projeto>.supabase.co
SUPABASE_PUBLISHABLE_KEY=<chave-publicável-de-produção>
```

Não publique nada nesta tarefa. Para subir depois, transporte separadamente migrations/dados, Auth, Storage, Functions, secrets, SMTP, OAuth e URLs. Preserve o Ultrabase local como desenvolvimento e rollback.

### Validação obrigatória

Antes de concluir:

1. execute o controlador com `-Action ensure -Json`;
2. valide que `ready` é `true` e HTTP é `200`;
3. valide o app com o Ultrabase;
4. execute os testes existentes e os novos;
5. teste CRUD e Auth;
6. teste dois usuários e RLS;
7. teste Storage/Realtime/RPA quando usados;
8. compare dados antes/depois da migração;
9. reinicie o app e confirme persistência;
10. faça varredura de segredos;
11. confirme que `.env.local` e arquivos equivalentes não entraram no Git;
12. não interrompa a stack para testar recuperação se outra migração estiver ativa;
13. crie commit local somente depois das provas.

### Entrega exigida

Informe:

1. app e banco detectados;
2. backup e origem preservada;
3. migrations e policies criadas;
4. contagens antes/depois;
5. configuração do runtime usada;
6. `app_slug`, `ultrabase.app.json` e objetos reservados;
7. Auth/Storage/Realtime/RPA envolvidos;
8. integrações autorizadas com `core_` ou outros apps;
9. modo offline implementado ou justificativa para não usar;
10. testes e resultados;
11. varredura de segredos;
12. rollback;
13. preparação para banco online;
14. commit local.

Execute o trabalho completo agora. Não apague a origem, não revele segredos, não crie outra instalação do Ultrabase e não publique externamente sem autorização explícita.

## FIM DO PROMPT
