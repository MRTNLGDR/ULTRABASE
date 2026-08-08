# Ultrabase — documentação unificada

## 1. Resultado entregue

O Ultrabase é um fork local do repositório oficial do Supabase, executado por Docker Compose e preparado para uso gratuito no próprio computador. Ele reúne banco PostgreSQL, painel no-code, autenticação, API REST, tempo real, arquivos, transformação de imagens, funções, pool de conexões e observabilidade.

Estado validado em 3 de agosto de 2026:

- 13 de 13 serviços saudáveis;
- painel Ultrabase com identidade e ícone em gradiente roxo, acessível em `http://127.0.0.1:8000`;
- acesso automático local habilitado, sem formulário ou desafio de login;
- PostgreSQL 17.6;
- Auth, REST, Storage, Realtime e Edge Functions testados de verdade;
- logs e Analytics locais habilitados com Logflare e Vector;
- portas publicadas somente em `127.0.0.1`;
- backup de banco, funções internas e Storage gerado e inspecionado;
- nenhum serviço pago, domínio ou nuvem contratado;
- nenhuma publicação externa realizada.
- runtime único instalado no início do Windows, com monitor oculto, recuperação automática e pausa reversível;
- contrato público central para os apps em `%LOCALAPPDATA%\Ultrabase`, sem credenciais administrativas.

O estado resumido e legível por máquina está em [`ULTRABASE-STATUS.json`](./ULTRABASE-STATUS.json).

## 2. Uso rápido, sem terminal

Abra a pasta [`ultrabase`](./ultrabase) e use os arquivos numerados:

| Arquivo | Função |
|---|---|
| `01-INICIAR-ULTRABASE.cmd` | Inicia o Docker Desktop se necessário e espera todos os serviços ficarem saudáveis. |
| `02-ABRIR-PAINEL-NO-CODE.cmd` | Inicia o Ultrabase e abre o Studio já liberado para este computador. |
| `03-MOSTRAR-CREDENCIAIS.cmd` | Mostra localmente o e-mail/senha de recuperação e a chave publicável para os apps. |
| `04-VALIDAR-TUDO.cmd` | Valida contêineres, Studio, Auth, REST, Storage, Realtime e Function. |
| `05-FAZER-BACKUP.cmd` | Gera banco, funções internas, Storage e manifesto em `docker/backups`. |
| `06-VER-LOGS.cmd` | Mostra os últimos logs da stack. |
| `07-ATIVAR-LOGS-E-ANALYTICS.cmd` | Habilita Logflare e Vector; reverte ao núcleo saudável se o download falhar. |
| `08-PARAR-SEM-APAGAR.cmd` | Para os serviços sem excluir banco nem arquivos. |
| `09-INSTALAR-RUNTIME-AUTOMATICO.cmd` | Instala/repara início oculto, monitor e configuração central dos apps. |
| `10-TESTAR-RUNTIME-DOS-APPS.cmd` | Executa 42 verificações do runtime e valida todos os serviços. |
| `11-REMOVER-INICIO-AUTOMATICO.cmd` | Remove atalho e monitor sem apagar banco, arquivos ou containers. |

Fluxo normal:

1. Na primeira preparação ou para reparar, dê duplo clique em `09-INSTALAR-RUNTIME-AUTOMATICO.cmd`.
2. Depois disso, o Windows mantém o runtime automaticamente; abra `02-ABRIR-PAINEL-NO-CODE.cmd` quando quiser o painel.
3. Use o Studio para criar tabelas, usuários, buckets, políticas, funções SQL e consultar logs.
4. Abra `03-MOSTRAR-CREDENCIAIS.cmd` somente quando precisar da chave publicável ou do acesso de recuperação.
5. Use `08-PARAR-SEM-APAGAR.cmd` para pausar de verdade; o monitor respeita a decisão até `01-INICIAR-ULTRABASE.cmd` ser usado.

## 3. O que está rodando

| Serviço | Papel no Ultrabase |
|---|---|
| Studio | Painel visual/no-code de administração. |
| PostgreSQL 17 | Banco relacional principal e fonte da verdade. |
| Auth | Cadastro, login, sessões, JWT, OAuth e MFA quando configurados. |
| PostgREST | Transforma tabelas, views e funções PostgreSQL em API REST. |
| Realtime | Entrega mudanças do banco e mensagens por WebSocket. |
| Storage | Buckets e arquivos com permissões controladas pelo PostgreSQL. |
| imgproxy | Redimensionamento e transformação de imagens. |
| Edge Runtime | Executa Functions em JavaScript, TypeScript e WASM. |
| Kong | Porta de entrada única para painel e APIs. |
| postgres-meta | Administração do PostgreSQL usada pelo Studio. |
| Supavisor | Pool de conexões PostgreSQL para muitos aplicativos. |
| Logflare | Logs e Analytics locais. |
| Vector | Coleta e encaminha logs dos contêineres. |

Arquitetura:

```text
Aplicativos locais
        |
        v
http://127.0.0.1:8000  (Kong)
        |
        +-- Auth
        +-- REST / PostgREST
        +-- Realtime
        +-- Storage + imgproxy
        +-- Edge Functions
        +-- Studio / postgres-meta
        |
        v
PostgreSQL 17 + Supavisor
        |
        +-- Logflare + Vector
```

## 4. Origem e identidade do fork

- Upstream oficial: `https://github.com/supabase/supabase.git`.
- Remote local: `upstream`.
- Branch do produto: `ultrabase`.
- Snapshot inicial: `c0f1ef51fb9c083ab3a2e6867def0c4c7b2fa521`.
- Projeto exibido no Studio: `Ultrabase Local`.
- Organização exibida no Studio: `Ultrabase`.
- Marca visual: `Ultrabase`, ícone e acentos em gradiente roxo.
- Imagem local do painel: `ultrabase/studio:2026.08-purple-v1`.
- Licença do repositório principal: Apache 2.0.

O clone foi feito com histórico raso para cumprir a prioridade de velocidade, mas o trabalho atual está completo. Se um dia for necessário todo o histórico antigo, execute uma vez `git fetch --unshallow upstream`.

Não foi criado repositório remoto nem foi feito push para uma conta externa. Isso evita publicar código ou dados sem autorização. Para transformar o fork local em repositório GitHub, basta depois criar o repositório `Ultrabase`, adicionar o remote `origin` e fazer o primeiro push.

## 5. Gratuito e open source: o que isso significa

O software self-hosted não cobra licença mensal. Na máquina atual, o custo direto do serviço é zero. Ainda existem custos físicos possíveis: computador ligado, energia, disco, internet e eventual domínio/VPS quando houver publicação.

O self-hosted contém o núcleo open source, mas não copia todas as conveniências comerciais da plataforma gerenciada. Branching hospedado, backup gerenciado/PITR, alta disponibilidade pronta, ETL gerenciado, API de administração da plataforma e operação 24/7 continuam sendo responsabilidade do proprietário. A própria documentação oficial diferencia a [instalação self-hosted](https://supabase.com/docs/guides/self-hosting) da plataforma gerenciada.

Referências oficiais:

- [Self-hosting com Docker](https://supabase.com/docs/guides/self-hosting/docker)
- [Desenvolvimento local](https://supabase.com/docs/guides/local-development)
- [Banco PostgreSQL do Supabase](https://supabase.com/docs/guides/database/overview)
- [Restauração da plataforma para self-hosted](https://supabase.com/docs/guides/self-hosting/restore-from-platform)

## 6. Segurança local aplicada

O Ultrabase não está publicado na rede inteira. As portas externas estão presas ao loopback:

- HTTP/API/Studio: `127.0.0.1:8000`;
- HTTPS reservado: `127.0.0.1:8443`;
- PostgreSQL em modo sessão: `127.0.0.1:5432`;
- PostgreSQL em modo transação: `127.0.0.1:6543`.

Outras proteções:

- e-mail local `admin@ultrabase.local` e senha aleatória de 32 caracteres para recuperação;
- credencial guardada no Gerenciador de Credenciais do Windows como `Ultrabase-Local-Studio`;
- acesso ao painel sem novo login somente quando o overlay local prende todas as portas em `127.0.0.1`;
- chaves JWT assimétricas modernas;
- `.env` ignorado pelo Git;
- chave secreta, service role e senha do PostgreSQL nunca exibidas pelo botão de credenciais;
- usuários anônimos desabilitados;
- cadastro por telefone desabilitado até existir um provedor real;
- Functions exigindo JWT;
- e-mail autoconfirmado apenas para permitir desenvolvimento local sem pagar SMTP.

O acesso automático não deve ser usado se o painel sair de `127.0.0.1`. Para produção pública, remova `ULTRABASE_LOCAL_AUTO_ACCESS`, reative autenticação no gateway, desligue o autoconfirm de e-mail, configure SMTP real, exija HTTPS, prepare firewall/domínio e envie os backups para outra máquina.

## 7. Como todos os aplicativos locais usam o Ultrabase

Cada aplicativo precisa de somente duas configurações públicas:

```dotenv
SUPABASE_URL=http://127.0.0.1:8000
SUPABASE_PUBLISHABLE_KEY=<mostrar com 03-MOSTRAR-CREDENCIAIS.cmd>
```

O modelo está em [`ultrabase/APPS-CONEXAO.env.example`](./ultrabase/APPS-CONEXAO.env.example).

O runtime já gera os valores reais, fora do Git, em:

```text
C:\Users\lucas\AppData\Local\Ultrabase\connection.json
C:\Users\lucas\AppData\Local\Ultrabase\connection.env
C:\Users\lucas\AppData\Local\Ultrabase\runtime-status.json
```

Também registra `ULTRABASE_HOME`, `ULTRABASE_URL`, `ULTRABASE_CONNECTION_FILE` e `ULTRABASE_ENV_FILE` para novos processos do usuário. O contrato contém a chave publicável, mas nunca senha do PostgreSQL, service role, chave secreta ou senha do painel.

Antes de conectar, cada app pode executar silenciosamente o controlador com `-Action ensure -Json`. Código 0 e `ready: true` liberam o uso. Código 2 significa que o proprietário pausou o serviço; o app não deve forçar a retomada.

Regras obrigatórias:

1. Frontend, mobile e desktop distribuído usam apenas a chave publicável.
2. `SUPABASE_SECRET_KEY`, `SERVICE_ROLE_KEY` e `POSTGRES_PASSWORD` nunca entram em frontend.
3. Toda tabela acessível por clientes deve ter Row Level Security (RLS).
4. Cada app deve ter políticas próprias; não compartilhe acesso total só porque o banco é central.
5. Use um schema ou prefixo por app e mantenha migrations versionadas.
6. Dados compartilhados de identidade podem ficar num núcleo comum; dados sensíveis de produtos sem relação devem ser isolados por schema ou por instância.

Os redirecionamentos locais mais comuns já estão preparados para portas `3000` e `5173`, em `localhost` e `127.0.0.1`. Para outro endereço, acrescente a URL exata em `ADDITIONAL_REDIRECT_URLS` dentro de `docker/.env` e recrie o serviço Auth.

Aplicativos em outro computador ou celular não conseguem acessar `127.0.0.1` desta máquina — isso é proposital. Para esse cenário, a próxima etapa segura é VPN privada (por exemplo, Tailscale/WireGuard) ou publicação com reverse proxy, HTTPS, firewall e DNS. Não mude simplesmente a porta para `0.0.0.0`.

## 8. Uso no-code pelo Studio

No painel:

- **Table Editor:** crie tabelas, colunas, relacionamentos e registros.
- **Authentication:** veja usuários, provedores e sessões.
- **Storage:** crie buckets públicos ou privados e gerencie arquivos.
- **Database / Policies:** habilite RLS e crie políticas por usuário/app.
- **Database / Functions:** crie funções PostgreSQL expostas por RPC quando necessário.
- **API Docs:** copie exemplos de consulta já gerados para as tabelas.
- **Logs:** consulte os eventos coletados por Logflare/Vector.

Para começar com segurança em cada tabela criada visualmente:

1. Ative RLS.
2. Crie uma política de leitura/escrita com base em `auth.uid()`.
3. Teste como usuário comum, nunca somente com service role.
4. Só então conecte o aplicativo.

## 9. Backups

Dê duplo clique em `05-FAZER-BACKUP.cmd`. O pacote vai para `docker/backups` e inclui:

- `AAAAmmdd-HHMMSS-database.dump`: banco em formato custom do PostgreSQL;
- `AAAAmmdd-HHMMSS-roles.sql`: funções/roles internas;
- `AAAAmmdd-HHMMSS-storage.zip`: arquivos do Storage, inclusive quando ainda está vazio;
- `AAAAmmdd-HHMMSS-manifest.txt`: data, commit e composição do pacote.

Os arquivos de backup são ignorados pelo Git. O `docker/.env` não é copiado porque contém segredos; ele deve ser guardado separadamente em cofre criptografado.

O backup de prova foi validado com `pg_restore --list` e com leitura do ZIP. Isso confirma que os arquivos são reconhecíveis. Um ensaio integral de restauração deve ser feito periodicamente numa segunda instância vazia; nunca restaure por cima da instância ativa sem um plano de rollback.

Sequência de restauração em uma instância nova:

1. Instale a mesma versão do Ultrabase.
2. Pare os serviços dependentes e deixe o PostgreSQL disponível.
3. Restaure `roles.sql` com `psql`, conciliando roles já existentes.
4. Restaure `database.dump` com `pg_restore` e `ON_ERROR_STOP`.
5. Extraia `storage.zip` no volume de Storage.
6. Configure `.env`, OAuth, SMTP, domínios e Functions.
7. Recrie os serviços e execute `04-VALIDAR-TUDO.cmd`.

## 10. Atualização sem perder o fork

Antes de qualquer atualização:

1. Execute `05-FAZER-BACKUP.cmd`.
2. Leia `docker/CHANGELOG.md` e `docker/versions.md`.
3. Confira se há mudanças de banco ou incompatibilidades.

Fluxo Git:

```powershell
git fetch upstream
git merge --no-edit upstream/master
```

Depois, dentro de `docker`:

```powershell
docker compose pull
docker compose up -d --wait
```

Finalize executando `ultrabase/04-VALIDAR-TUDO.cmd`. Nunca use `git reset --hard` nem apague `docker/volumes/db/data` ou `docker/volumes/storage` para “resolver” uma atualização.

## 11. Migração futura

### Para Supabase Cloud ou outro Ultrabase self-hosted

É o caminho mais simples, pois ambos usam PostgreSQL e os mesmos schemas. Transporte separadamente:

- roles;
- schema;
- dados;
- arquivos de Storage;
- Edge Functions;
- configurações de Auth/OAuth;
- SMTP, domínios e secrets.

O dump do banco inclui `auth.users`, mas tokens existentes deixam de valer quando as chaves JWT mudam; os usuários podem precisar entrar novamente. A documentação oficial de [restauração para self-hosted](https://supabase.com/docs/guides/self-hosting/restore-from-platform) detalha essa separação.

### Para qualquer PostgreSQL

Tabelas, dados, índices, views, triggers e funções compatíveis podem ser levados por `pg_dump`/`pg_restore`. Extensões específicas precisam existir no destino. Auth, Storage, Realtime e Functions não “viram PostgreSQL puro” automaticamente; é preciso manter esses serviços ou substituí-los.

### Para MySQL, SQLite, SQL Server ou MongoDB

Não é uma troca automática. É necessário converter tipos, constraints, funções, RLS, triggers, consultas e integrações. A melhor defesa contra aprisionamento é:

- manter SQL e migrations versionados;
- concentrar o acesso a dados numa camada por app;
- evitar espalhar chamadas específicas do Supabase por todo o produto;
- usar Storage compatível com S3 quando houver publicação;
- separar regras de negócio das APIs de infraestrutura;
- testar exportação e restauração regularmente.

## 12. Publicação futura

Existem três destinos naturais:

1. **Supabase gerenciado:** menos operação, possível custo mensal.
2. **VPS próprio com Docker Compose:** software gratuito; paga-se o servidor e você opera segurança/backup.
3. **Servidor local acessado por VPN:** mantém dados em casa, mas depende de energia, internet e disponibilidade da máquina.

Checklist mínimo antes de sair do computador local:

- domínio e DNS;
- HTTPS válido;
- reverse proxy;
- firewall com portas mínimas;
- SMTP real;
- e-mail sem autoconfirm;
- OAuth com callbacks novos;
- secrets em cofre;
- backup externo e restauração testada;
- monitoramento e alertas;
- plano de atualização e rollback;
- capacidade e disponibilidade definidas.

## 13. Arquivos que não devem ser apagados

- `docker/.env`: credenciais e configuração local;
- `docker/volumes/db/data`: dados do PostgreSQL;
- `docker/volumes/storage`: arquivos do Storage;
- `docker/backups`: backups gerados;
- `docker/docker-compose.ultrabase-local.yml`: isolamento de rede e volume de backup;
- `docker/studio-ultrabase/Dockerfile`: camada visual do Studio sobre a imagem oficial;
- `apps/studio/styles/ultrabase.css`: tokens e gradientes da marca;
- `docker/volumes/api/kong-entrypoint.sh`: libera o painel somente quando o modo local explícito está ativo;
- `ultrabase/scripts/ultrabase.ps1`: operação dos botões.

O script oficial `docker/reset.sh` é destrutivo e remove dados. Ele não faz parte do fluxo normal do Ultrabase.

## 14. Provas executadas

- clone oficial: 16.610 arquivos no snapshot inicial;
- Docker Compose resolvido sem erros;
- 13/13 contêineres `healthy`;
- bind externo restrito a `127.0.0.1` nas quatro portas publicadas;
- Studio sem desafio de login em loopback: HTTP 200 e sem `WWW-Authenticate`;
- HTML com título `Ultrabase`;
- imagem ativa `ultrabase/studio:2026.08-purple-v1`;
- logo, favicon e CSS roxos aprovados; cores verdes antigas ausentes do logo servido;
- e-mail/senha de recuperação gerados e credencial confirmada no Windows;
- Auth health: HTTP 200;
- cadastro e sessão: aprovado, usuário de teste removido;
- REST administrativo: HTTP 200;
- Storage: HTTP 200;
- Realtime: healthy;
- Edge Function `hello`: resposta aprovada com JWT;
- PostgreSQL: 17.6;
- launcher testado com Docker Desktop inicialmente desligado;
- backup de banco: 308.640 bytes e catálogo reconhecido por `pg_restore`;
- backup de roles: 7.571 bytes;
- backup de Storage: ZIP reconhecido;
- segredos usados no teste visual foram invalidados e toda a stack foi recriada antes da validação final.

## 15. Limite de responsabilidade desta entrega

O Ultrabase está completo e operacional localmente. Conectar cada aplicação exige editar as duas variáveis públicas do próprio app e criar suas tabelas/políticas. Publicar na internet, criar um repositório GitHub remoto ou migrar dados de um sistema existente não foi feito porque são ações externas e destinos que precisam ser escolhidos explicitamente.

## 16. Documentação oficial offline e manual para aplicativos

A fonte oficial versionada da documentação Supabase presente no fork foi inventariada e empacotada para consulta sem internet:

- 813 arquivos em `apps/docs/content`, sendo 812 documentos MDX;
- manual mestre em português para frontend, backend, RPA, banco interno, Auth, Storage, Realtime, Functions, migrations e backup;
- inventário CSV com caminho, tamanho e SHA-256 de cada arquivo;
- manifesto JSON com commit, contagens e hash do pacote;
- ZIP local transportável, sem duplicação no histórico Git.

Comece em [`ultrabase/documentacao/README.md`](./ultrabase/documentacao/README.md) ou vá direto ao [`ULTRABASE-MANUAL-MESTRE.md`](./ultrabase/documentacao/ULTRABASE-MANUAL-MESTRE.md).

## 17. Runtime automático compartilhado pelos aplicativos

Foi instalada uma única instância por usuário, em vez de empacotar treze serviços dentro de cada app. O atalho `Ultrabase Local Runtime.lnk` fica na pasta de Inicialização do Windows e chama um monitor PowerShell oculto. O monitor:

- garante uma única execução por mutex;
- inicia Docker Desktop e Ultrabase quando necessário;
- verifica a saúde a cada minuto;
- recupera indisponibilidade inesperada;
- não reinicia quando existe a pausa criada pelo botão 08;
- grava somente estado e log operacional em `%LOCALAPPDATA%\Ultrabase`;
- não copia segredos administrativos para os apps.

O controlador é [`ultrabase/runtime/Ultrabase-Runtime.ps1`](./ultrabase/runtime/Ultrabase-Runtime.ps1), o contrato está descrito em [`ultrabase/runtime/README.md`](./ultrabase/runtime/README.md) e o texto a enviar para cada aplicativo está em [`PROMPT-PARA-CONECTAR-QUALQUER-APP.md`](./ultrabase/runtime/PROMPT-PARA-CONECTAR-QUALQUER-APP.md).

Aplicativos escrevem pela API enquanto `ready` for verdadeiro. Se precisarem continuar operando com o runtime pausado, implementam uma outbox SQLite com idempotência e sincronizam quando o Ultrabase retornar; nenhum pacote estático recebe gravação enquanto o servidor está desligado.
