# Ultrabase

Fork local do Supabase, preparado para uso gratuito, self-hosted e orientado ao painel no-code com identidade Ultrabase em gradiente roxo.

## Comece aqui

O ponto de entrada oficial do projeto é **`RUN.bat` na raiz**. Para uso normal, clique somente nele. O motor compartilhado configurado na máquina cuida de atualização do Git, instalação, recuperação/subida do runtime e abertura do navegador.

Opções suportadas pelo ponto de entrada único:

```text
RUN.bat
RUN.bat /sem-navegador
RUN.bat /sem-pull
RUN.bat /reinstalar
RUN.bat /parar
```

Os `.cmd` e scripts históricos dentro de `ultrabase/` continuam versionados porque fazem parte da implementação e da recuperação do runtime, mas **não são mais o caminho normal de inicialização para o usuário**. A regra operacional vigente está em [`AGENTS.md`](./AGENTS.md).

O **Ultrabase Local Runtime** mantém uma única stack local compartilhada por todos os apps. O endpoint canônico do cliente é `http://127.0.0.1:8000`.

A documentação da instalação está em [`ULTRABASE-DOCUMENTACAO-UNIFICADA.md`](./ULTRABASE-DOCUMENTACAO-UNIFICADA.md).

Para conectar aplicativos, backends, RPA ou bancos internos, comece pelo [`Manual Mestre de uso e integração`](./ultrabase/documentacao/ULTRABASE-MANUAL-MESTRE.md). A [`documentação oficial offline`](./ultrabase/documentacao/README.md) contém o inventário dos 813 arquivos do snapshot e o manifesto de integridade.

Prompt pronto para qualquer aplicativo: [`PROMPT-PARA-CONECTAR-QUALQUER-APP.md`](./ultrabase/runtime/PROMPT-PARA-CONECTAR-QUALQUER-APP.md).

Organização de vários apps e estado real do pacote: [`ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md`](./ultrabase/runtime/ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md). A decisão oficial é um Ultrabase físico com namespace e RLS por app. O ZIP transportável não inclui banco vivo, segredos ou imagens Docker e não é um executável independente.

Aplicação segura e auditável de migrations de qualquer app: [`APP-MIGRATIONS.md`](./ultrabase/runtime/APP-MIGRATIONS.md). O controlador interno valida namespace, bloqueia alterações em domínios alheios, exige backup, registra checksums imutáveis e mantém migration + ledger na mesma transação. Ele é ferramenta administrativa/automática, não um segundo inicializador de usuário.

Estado verificável: [`ULTRABASE-STATUS.json`](./ULTRABASE-STATUS.json).
