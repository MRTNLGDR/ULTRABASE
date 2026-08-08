# Ultrabase Local Runtime

Este runtime mantém uma única instalação do Ultrabase disponível para todos os aplicativos deste computador.

A arquitetura oficial é **um banco físico compartilhado com um namespace lógico por app**. Leia [`ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md`](./ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md) antes de criar tabelas, buckets, funções ou migrations.

## Instalação sem terminal

Abra `ultrabase/09-INSTALAR-RUNTIME-AUTOMATICO.cmd` uma vez. O instalador:

- registra o início oculto no login do Windows para o usuário atual;
- inicia o Docker Desktop quando necessário;
- inicia e recupera a stack do Ultrabase;
- gera configuração pública central para os apps;
- registra variáveis de ambiente de descoberta;
- inicia um monitor leve, único e oculto;
- não copia senha PostgreSQL, chave secreta ou service role.

## Arquivos centrais dos aplicativos

O runtime gera localmente, fora do Git:

```text
%LOCALAPPDATA%\Ultrabase\connection.json
%LOCALAPPDATA%\Ultrabase\connection.env
%LOCALAPPDATA%\Ultrabase\runtime-status.json
```

Variáveis de usuário registradas:

```text
ULTRABASE_HOME
ULTRABASE_URL
ULTRABASE_CONNECTION_FILE
ULTRABASE_ENV_FILE
```

`connection.json` e `connection.env` contêm somente a URL local e a chave publicável que pode ser usada por clientes protegidos por RLS. Eles não contêm credenciais administrativas.

## Contrato para os apps

Ao iniciar, o aplicativo executa o controlador com `-Action ensure -Json`. Se o resultado tiver `ready: true`, pode usar a URL e a chave publicável do arquivo central. Se o usuário tiver pausado o runtime, o controlador retorna código 2 e não desobedece à pausa.

Frontends escrevem pela Data API/SDK, nunca nas pastas do PostgreSQL. Backends confiáveis podem usar PostgreSQL somente com credencial limitada e protegida.

Cada app deve reservar um `app_slug`, versionar `ultrabase.app.json` no próprio repositório e prefixar tabelas, views, RPCs, buckets, Functions, canais e migrations. Um app não pode escrever diretamente no prefixo de outro.

## O que já está empacotado

- **Pronto nesta máquina:** instalação automática, início com o Windows, monitor, recuperação e configuração pública dos apps.
- **Pronto para consulta/transporte:** ZIP com documentação e scripts públicos do runtime.
- **Fora do ZIP de propósito:** banco vivo, Storage e segredos; eles usam backup e restauração separados.
- **Ainda não produzido:** instalador totalmente offline com imagens Docker ou executável único sem containers.

O ZIP é um pacote de documentação e operação, não um servidor. Apps só escrevem quando os serviços estão ativos; o controlador liga o Docker Desktop quando necessário.

## Pausa e retomada

`08-PARAR-SEM-APAGAR.cmd` cria uma pausa persistente, impede o monitor de religar a stack e preserva todos os dados. `01-INICIAR-ULTRABASE.cmd` remove a pausa e retoma o serviço.

## Remoção reversível

`11-REMOVER-INICIO-AUTOMATICO.cmd` remove o atalho do login e encerra somente o monitor. Banco, arquivos, Docker, configuração pública e containers são preservados.
