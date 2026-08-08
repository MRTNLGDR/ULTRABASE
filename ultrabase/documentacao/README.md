# Documentação offline do Ultrabase

Esta pasta transforma a documentação técnica completa do fork em um pacote utilizável e verificável.

## Comece por aqui

1. Leia [`ULTRABASE-MANUAL-MESTRE.md`](./ULTRABASE-MANUAL-MESTRE.md) para decidir como cada app, backend, RPA ou ferramenta deve se conectar.
2. Use [`REFERENCIAS-OFICIAIS.md`](./REFERENCIAS-OFICIAIS.md) para abrir os assuntos oficiais mais importantes.
3. Consulte [`INVENTARIO-DOCUMENTACAO-OFICIAL.csv`](./INVENTARIO-DOCUMENTACAO-OFICIAL.csv) para localizar qualquer um dos 813 arquivos do snapshot.
4. Verifique versão, contagens e integridade no [`MANIFESTO-DOCUMENTACAO.json`](./MANIFESTO-DOCUMENTACAO.json).

## Onde está a cópia integral

A fonte completa já faz parte deste fork em:

```text
apps/docs/content/
```

Os documentos usam MDX, um formato Markdown com componentes. Eles podem ser pesquisados e lidos em qualquer editor de texto. O arquivo `ultrabase-documentacao-oficial-offline.zip` reúne essa árvore, os documentos de operação Docker, a licença e os manuais do Ultrabase para transporte ou consulta sem internet.

O ZIP é gerado localmente e não é versionado no Git para evitar duplicar milhares de arquivos que já estão no repositório. Sua integridade é registrada por SHA-256 no manifesto.

## Atualização do pacote

Quando o fork for atualizado a partir do upstream oficial:

1. leia os changelogs;
2. regenere inventário e ZIP;
3. atualize os hashes e o commit no manifesto;
4. revise o manual se o comportamento oficial tiver mudado;
5. valide a stack antes de considerar a documentação atualizada.
