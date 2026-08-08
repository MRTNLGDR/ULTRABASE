# Ultrabase

Fork local do Supabase, preparado para uso gratuito, self-hosted e orientado ao painel no-code com identidade Ultrabase em gradiente roxo.

## Comece aqui

O **Ultrabase Local Runtime já está instalado no início do Windows** para o usuário atual. Ele inicia o Docker Desktop quando necessário, recupera a stack e mantém uma única conexão para todos os apps.

1. Normalmente, apenas abra `ultrabase/02-ABRIR-PAINEL-NO-CODE.cmd`.
2. Se o runtime tiver sido pausado, abra `ultrabase/01-INICIAR-ULTRABASE.cmd`.
3. Para reinstalar ou reparar o início automático, abra `ultrabase/09-INSTALAR-RUNTIME-AUTOMATICO.cmd`.

O painel local abre automaticamente, sem pedir login, porque aceita conexões somente deste computador. Use `03-MOSTRAR-CREDENCIAIS.cmd` para consultar o acesso de recuperação e a chave publicável dos aplicativos.

A documentação da instalação está em [`ULTRABASE-DOCUMENTACAO-UNIFICADA.md`](./ULTRABASE-DOCUMENTACAO-UNIFICADA.md).

Para conectar aplicativos, backends, RPA ou bancos internos, comece pelo [`Manual Mestre de uso e integração`](./ultrabase/documentacao/ULTRABASE-MANUAL-MESTRE.md). A [`documentação oficial offline`](./ultrabase/documentacao/README.md) contém o inventário dos 813 arquivos do snapshot e o manifesto de integridade.

Prompt pronto para qualquer aplicativo: [`PROMPT-PARA-CONECTAR-QUALQUER-APP.md`](./ultrabase/runtime/PROMPT-PARA-CONECTAR-QUALQUER-APP.md).

Organização de vários apps e estado real do pacote: [`ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md`](./ultrabase/runtime/ARQUITETURA-MULTIAPP-E-EMPACOTAMENTO.md). A decisão oficial é um Ultrabase físico com namespace e RLS por app. O runtime já está instalado e automático nesta máquina; o ZIP transportável não inclui banco vivo, segredos ou imagens Docker e não é um executável independente.

Estado verificável: [`ULTRABASE-STATUS.json`](./ULTRABASE-STATUS.json).
