<!-- REGRA-RUN-BAT :: nao remover -->
# REGRA OBRIGATORIA — INICIALIZADOR UNICO (`RUN.bat`)

**Vale para qualquer agente e para o usuario.**

O ULTRABASE tem um unico ponto de entrada humano: **`RUN.bat`, na raiz**.
Um clique nele executa, nesta ordem:

1. atualizacao Git segura por fast-forward, preservando mudancas locais;
2. validacao/geracao criptografica de `docker/.env` fora do Git;
3. verificacao do Docker Desktop e do Docker Compose;
4. instalacao/reparo do runtime local e inicio da stack;
5. health checks reais e abertura do Studio em `http://127.0.0.1:8000`.

Opcoes: `RUN.bat /sem-navegador` · `/sem-pull` · `/reinstalar` · `/parar`.

## Implementacao interna

O comportamento versionado do produto vive em:

```text
ultrabase/runtime/Ultrabase-Bootstrap.ps1
ultrabase/runtime/Ultrabase-Runtime.ps1
ultrabase/scripts/ultrabase.ps1
ultrabase/runtime/generate-ultrabase-env.mjs
```

Esses arquivos sao **controladores internos**, nao novos inicializadores para o usuario. Eles podem e devem ser evoluidos e testados no repositorio. O arquivo opcional `D:\AGENT_SYNC\motor-run.ps1` existe apenas como compatibilidade de emergencia quando uma copia antiga estiver incompleta; uma instalacao normal do ULTRABASE nao depende dele.

## O que nao pode ser feito

- Nao criar outro `.bat`, `.cmd`, `.ps1` ou `.sh` como segundo ponto de entrada humano.
- Nao orientar o usuario a executar scripts internos em sequencia; a instrucao normal e sempre clicar no `RUN.bat`.
- Nao usar mocks, respostas simuladas ou status escritos manualmente como prova de funcionamento.
- Nao usar `git reset --hard`, apagar alteracoes locais, executar `docker compose down -v` ou remover `docker/volumes/db/data`/`docker/volumes/storage` para corrigir problemas.
- Nao versionar `docker/.env`, chaves, banco vivo, Storage vivo, dumps ou relatorios com segredos.
- Nao rotacionar automaticamente credenciais quando o PostgreSQL ja possui dados. Nessa situacao, restaurar o `.env` original do cofre/backup.

## Gates obrigatorios

Mudancas de runtime so estao concluidas quando os gates aplicaveis passam:

- parser do Windows PowerShell;
- geracao e verificacao criptografica de HS256, ES256/JWKS e chaves opacas;
- protecao Git de segredos e dados vivos;
- `docker compose config --quiet`;
- stack real com containers saudaveis;
- Auth com usuarios reais e tokens ES256;
- REST com CRUD e testes negativos de RLS;
- GraphQL real;
- Realtime entregando uma alteracao PostgreSQL;
- Storage privado com RLS e comparacao byte a byte;
- Edge Function exigindo JWT;
- dump PostgreSQL reconhecido e restaurado em banco temporario.

A prova automatizada completa esta em `.github/workflows/ultrabase-self-hosted-acceptance.yml` e `ultrabase/runtime/verify-ultrabase-real.mjs`.

## Regras tecnicas

- Scripts `.ps1` consumidos pelo Windows PowerShell 5.1 devem ser UTF-8 com BOM quando contiverem caracteres fora de ASCII.
- Chamadas nativas devem verificar `$LASTEXITCODE`; saida em `stderr` nao deve ser confundida automaticamente com falha.
- Atualizacao Git usa `fetch` + `pull --ff-only`; trabalho local vai para stash e volta depois.
- Reinstalacao atualiza imagens e reconstrui o Studio, mas nunca apaga volumes de dados.
- O painel sem Basic Auth so e permitido no overlay local que publica portas exclusivamente em `127.0.0.1`.

<!-- fim REGRA-RUN-BAT -->
