# Ultrabase multiapp e empacotamento

Este documento fixa a arquitetura oficial do Ultrabase neste computador e elimina duas ambiguidades: como vários aplicativos compartilham a mesma instalação sem misturar dados e o que significa dizer que o sistema está “empacotado”.

## Decisão oficial

Existe **um único Ultrabase físico**, com uma stack, um projeto local (`default`) e um PostgreSQL. Cada aplicativo ocupa um **domínio lógico próprio** dentro desse banco. Não se cria outro Docker, outra stack ou outro projeto local para cada app.

Esse modelo não vira bagunça quando o contrato abaixo é seguido. Cada objeto tem dono identificável, migrations permanecem no repositório do app e o acesso entre domínios é proibido por padrão.

Uma instalação separada só deve existir quando houver uma fronteira real de confiança: outro cliente, outra organização administradora, exigência jurídica ou de residência de dados, política de retenção incompatível, ou necessidade de backup e restauração totalmente independentes.

## Identidade obrigatória do aplicativo

Antes de criar qualquer objeto, o app escolhe um `app_slug` exclusivo e imutável:

- somente letras minúsculas ASCII, números e sublinhado;
- começa por uma letra;
- tem de 2 a 24 caracteres;
- não pode ser `auth`, `storage`, `realtime`, `extensions`, `supabase_functions`, `vault`, `graphql` ou `core`;
- não pode colidir com o slug de outro app;
- não muda depois que a primeira migration entra em uso.

Exemplos válidos: `ach`, `oraculo`, `arcz`, `avangard_one`.

Antes de reservar o slug, o integrador deve inspecionar tabelas, views, funções SQL, buckets, Edge Functions e migrations existentes. A reserva é registrada no repositório do aplicativo em `ultrabase.app.json`:

```json
{
  "schema_version": 1,
  "app_slug": "ach",
  "display_name": "Artistic Career Hub",
  "table_prefix": "ach_",
  "migrations_path": "supabase/migrations",
  "buckets": ["ach-files"],
  "edge_functions": [],
  "shared_dependencies": ["auth.users"],
  "database_owner": "Ultrabase Local"
}
```

Esse manifesto pertence ao app, não contém chave nem senha e deve ser versionado no Git junto das migrations.

## Convenção que impede colisões

| Recurso | Formato obrigatório | Exemplo |
|---|---|---|
| Tabela em `public` | `<app_slug>_<entidade>` | `ach_projects` |
| View | `<app_slug>_v_<nome>` | `ach_v_public_profiles` |
| Função SQL/RPC | `<app_slug>_<acao>` | `ach_publish_project` |
| Índice | `<tabela>_<colunas>_idx` | `ach_projects_owner_id_idx` |
| Constraint exclusiva | `<tabela>_<colunas>_key` | `ach_projects_slug_key` |
| Bucket do Storage | `<app-slug>-<finalidade>` | `ach-files` |
| Edge Function | `<app-slug>-<acao>` | `ach-send-invite` |
| Canal Realtime | `<app_slug>:<escopo>:<id>` | `ach:project:42` |
| Migration | `<timestamp>_<app_slug>_<mudanca>.sql` | `20260803010000_ach_create_projects.sql` |

Para nomes usados fora do PostgreSQL, o sublinhado do slug pode ser convertido em hífen. Objetos compartilhados intencionalmente usam o prefixo reservado `core_` e ficam sob governança do Ultrabase; um app não transforma unilateralmente sua tabela em recurso compartilhado.

## Limites entre os apps

Cada app pode criar e alterar somente objetos com seu prefixo, além de policies relacionadas ao próprio domínio. As seguintes regras são obrigatórias:

1. migrations são a fonte oficial do schema e ficam em `supabase/migrations` no repositório do app;
2. toda tabela exposta tem RLS e policies próprias;
3. frontend usa sessão do usuário e chave publicável, nunca `service_role`;
4. um app não escreve diretamente nas tabelas de outro prefixo;
5. integração entre apps passa por uma view, RPC ou contrato `core_` documentado e autorizado;
6. `auth.users` é a identidade compartilhada, mas permissões e perfis específicos continuam no domínio de cada app;
7. buckets, Edge Functions, tópicos Realtime, jobs e logs seguem o slug;
8. schemas internos do Supabase não são alterados manualmente;
9. qualquer mudança destrutiva exige backup, rollback e conferência de consumidores;
10. segredos nunca entram no manifesto do app, migration, cliente ou Git.

Um catálogo central de apps pode usar futuramente `core_applications` e `core_app_memberships`, mas essas tabelas **não são declaradas como existentes** até que migrations próprias sejam criadas e aprovadas.

## Auth compartilhado sem misturar autorização

Uma pessoa pode possuir uma única identidade em `auth.users` e acessar vários apps. Isso não concede acesso automático a nenhum domínio. Cada app mantém sua associação ou perfil, por exemplo `ach_profiles` ou `arcz_memberships`, e suas policies verificam essa associação.

Assim, login pode ser reutilizado, mas dados e autorização permanecem isolados por RLS. Se dois apps precisarem de login totalmente independente, administradores diferentes ou usuários que não possam nem compartilhar o mesmo diretório de identidade, isso é uma razão para outra instância.

## Banco local, backup e subida online

O banco físico é único, porém cada app leva suas próprias migrations e seu `ultrabase.app.json`. Essa separação permite reconstruir ou migrar um domínio sem copiar o código de todos os outros.

Para subir um app depois:

1. crie o destino PostgreSQL/Supabase online;
2. aplique somente as migrations e funções pertencentes ao slug do app, mais dependências `core_` declaradas;
3. transporte os registros desse prefixo preservando IDs e relacionamentos;
4. migre Auth, Storage, Edge Functions e secrets como etapas separadas;
5. recrie policies, SMTP, OAuth, URLs e variáveis do ambiente online;
6. compare contagens e integridade antes de trocar a URL do aplicativo;
7. preserve o Ultrabase local e a origem anterior até o aceite.

PostgreSQL, Auth, Storage e Functions não formam um único arquivo portátil. O backup completo continua sendo gerado separadamente pelos botões de backup do Ultrabase e deve ser tratado como material confidencial.

## Estado real do empacotamento

“Empacotado” pode significar coisas diferentes. O estado atual é:

| Camada | Estado | O que significa |
|---|---|---|
| Runtime instalado nesta máquina | **Pronto** | Atalho de início automático, monitor oculto, recuperação e contrato de conexão estão instalados para o usuário atual. |
| Código, documentação e runtime em ZIP transportável | **Pronto** | `ultrabase-documentacao-oficial-offline.zip` contém documentação e scripts públicos, sem segredos. |
| Dados vivos e arquivos do Storage | **Fora do ZIP** | São persistidos nos volumes e entram em backup próprio; não devem ser publicados junto da documentação. |
| Segredos e credenciais administrativas | **Fora do ZIP** | Permanecem locais e protegidos; precisam ser regenerados ao instalar em outra máquina. |
| Imagens Docker para instalação totalmente offline | **Não empacotadas** | O pacote atual não contém exportações das imagens, que ocupariam muitos gigabytes. |
| Instalador portátil completo para outro computador | **Ainda não produzido** | Outra máquina ainda precisa de Docker compatível, das imagens, da configuração segura e, se desejado, de restauração do backup. |
| Executável único sem Docker | **Não produzido e não recomendado** | O Ultrabase é uma composição de serviços; um `.exe` não substitui PostgreSQL, Auth, Storage, gateway e demais containers. |

Portanto, **sim: o Ultrabase está instalado e operacionalmente empacotado para uso automático nesta máquina**. **Não: ele ainda não é um instalador offline independente que possa ser copiado para qualquer PC e funcionar sem um runtime de containers**.

O ZIP não é um banco em execução. Apps não escrevem “dentro do pacote”; eles escrevem pela API em `http://127.0.0.1:8000` enquanto o runtime está pronto. Se o Docker estiver fechado, o controlador tenta iniciá-lo. Se o runtime estiver pausado ou não puder iniciar, o app precisa aguardar ou usar sua outbox local.

## Regra curta para qualquer integrador

> Use a única instalação do Ultrabase, reserve um `app_slug`, prefixe todos os recursos, versione `ultrabase.app.json` e migrations no app, aplique RLS, não escreva no domínio de outro app e nunca trate o ZIP como banco ou instalador completo.
