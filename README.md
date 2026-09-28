# Task Locked — OSRS

Randomizador de tasks de Old School RuneScape para um grupo de até 5 pessoas.
Cada um sorteia **a sua própria** task do pool compartilhado, faz no jogo e marca como concluída.

**Regras**

1. Gerar e concluir são ações individuais — não existe botão que sorteie para o grupo todo.
2. Duas pessoas nunca ficam com a **mesma task** (mesmo `id`). Tasks de *nome* igual e id diferente
   são permitidas: o dataset tem 161 pares repetidos e eles são tasks distintas e progressivas.
3. Task concluída sai do pool do grupo para sempre.
4. Tiers são sequenciais **no sorteio**: as 179 `easy` precisam estar todas concluídas antes de
   qualquer `medium`, e assim por diante. O tamanho do pool é o do
   [task-list.json](task-list.json) — hoje 997 tasks — e o app lê esse total do banco, então
   atualizar a lista não exige mexer em código (ver [Atualizar a lista](#atualizar-a-lista-de-tasks)).
5. Além da sua task do pool, cada um pode pegar **uma task extra**: uma que o grupo já concluiu,
   escolhida em `/completed`, para repetir. A extra não mexe no pool (ver
   [Tasks extra](#tasks-extra)).

**Telas:** `/board` (sua task + a extra + a do grupo) · `/completed` (o que já saiu, com o contador
de quantas pessoas fizeram cada task, o botão de pegar extra, busca e filtros por "já fiz / não fiz" e
por quem fez) · `/pending` (todas as tasks que faltam, com busca, filtro por tier e conclusão manual).

Stack: React + TypeScript + Tailwind (Vite) · Supabase (Postgres) · Cloudflare Pages.

---

## Como funciona

```
Browser (SPA)
   │  anon key — sem acesso direto a nenhuma tabela
   ▼
Supabase RPC   join_group · get_state · roll_task · complete_task · undo_complete
               list_completed · list_pending · complete_task_by_id
               take_extra_task · complete_extra_task
   ▼
Postgres  tasks · group_state · members · assignments · extra_assignments

               abandon_extra_task — existe, mas nenhuma tela chama:
               é válvula manual pelo SQL Editor (ver Tasks extra)
```

Todas as tabelas têm **RLS ligada sem nenhuma policy**, então a anon key não lê nem escreve nada
diretamente — ela é inofensiva mesmo estando no bundle. Tudo passa pelas funções `SECURITY DEFINER`,
que exigem o token do membro.

O sorteio acontece **inteiro dentro do Postgres**, numa transação, protegido por um advisory lock e
por dois índices únicos ([supabase/schema.sql](supabase/schema.sql)):

```sql
create unique index assignments_one_active_per_member on assignments (member_id) where status = 'active';
create unique index assignments_task_unique           on assignments (task_id);
```

Os índices são a garantia real: mesmo com um bug na lógica, o banco se recusa a gravar um estado
inválido. O front nunca decide qual task cai para quem.

### Tasks extra

Uma **extra** é uma task que o grupo já concluiu e alguém escolheu repetir. Ela fica no board ao
lado da task normal e **não mexe no pool**: não muda o tier atual, não muda o contador do grupo e
não tira nada da lista de pendentes.

O efeito aparece em `/completed`: cada linha traz o contador `n/total de membros` e **uma entrada
por pessoa que fez a task**, com nome e data — quem a tirou do pool primeiro, depois quem a repetiu
(marcada com `· extra`). A extra nunca vira uma linha nova na lista; ela entra na linha da task que
já existe. É o campo `completions` de `list_completed`:

```json
[{ "name": "Edu", "completed_at": "…", "extra": false },
 { "name": "Ana", "completed_at": "…", "extra": true  }]
```

| Regra | Onde é garantida |
|---|---|
| Só dá para pegar o que o grupo **já concluiu** | `take_extra_task` → `NOT_COMPLETED_YET` |
| Várias pessoas podem ter a **mesma** extra ao mesmo tempo | (sem restrição — a task já saiu do pool) |
| No máximo **uma** extra ativa por pessoa | índice `extra_assignments_one_active_per_member` |
| Ninguém faz a **mesma task duas vezes** | índice `extra_assignments_member_task_unique` |

Por que uma tabela separada e não mais uma linha em `assignments`: lá existe
`assignments_task_unique`, que garante que uma task nunca tem dois assignments — e uma extra aponta
justamente para uma task que já tem o seu. Guardar as extras à parte deixa aquele índice intacto,
e ele continua sendo a garantia das regras do pool.

**Não dá para devolver uma extra pelo site** — concluir é a única saída. Some as duas regras acima e
o efeito é que escolher errado tranca a pessoa: ela não pode pegar outra extra nem sair dessa. Por
isso a confirmação ao *pegar* é a mais enfática do app.

A RPC `abandon_extra_task` continua existindo no banco de propósito, como válvula manual: se alguém
ficar preso numa extra inviável, rodar isso no SQL Editor com o token da pessoa apaga a linha e a
destrava (e aquela task volta a ficar disponível como extra para ela). Nenhuma tela chama essa
função, e não há wrapper dela em [src/lib/api.ts](src/lib/api.ts).

> **Não há arquivos de migração:** o `schema.sql` é aplicado por cima do banco em produção, e isso
> basta (ver [Aplicar o schema](#2-aplicar-o-schema)). Vale a ordem de sempre ao mudar as duas
> pontas: **SQL antes, front depois** — o front antigo ignora campos novos e continua funcionando no
> intervalo, enquanto o contrário quebra a tela.

> **Por que polling e não Realtime:** o Postgres Changes do Supabase respeita RLS, e como nenhuma
> policy libera SELECT, ele não entregaria nada. O board faz polling de `get_state` a cada 3s (e
> refetch imediato após cada ação), o que para 5 pessoas é de sobra.

---

## Setup

### 1. Criar o projeto no Supabase

Crie um projeto em [supabase.com](https://supabase.com) (free tier). Em **Project Settings → API**,
copie a URL, a `anon` key e a `service_role` key.

```bash
cp .env.example .env.local   # e preencha as três variáveis
npm install
```

A `service_role` key é usada **só** pelos scripts locais. Ela nunca vai para o front —
o `.env.local` está no `.gitignore`.

### 2. Aplicar o schema

```bash
npm run schema
```

Precisa da `SUPABASE_DB_URL` no `.env.local`. Use a string do **Session pooler** (Project Settings →
Database → Connection string) — a "Direct connection" é IPv6-only desde que o Supabase tirou o IPv4
do free tier, e o "Transaction pooler" (porta 6543) não aceita DDL. O [.env.example](.env.example)
tem o formato exato.

Sem essa variável, o caminho manual continua valendo: copie o
[supabase/schema.sql](supabase/schema.sql) e cole no **SQL Editor** do Supabase.

**Mudou o schema? Roda o schema de novo.** Este projeto não cria um arquivo de migração por
alteração. O `schema.sql` é a fonte da verdade e é idempotente de ponta a ponta — só
`create table if not exists`, `create index if not exists` e `create or replace function`, sem um
`delete` ou `truncate` no arquivo inteiro. Rodar por cima de um banco em produção preserva tasks,
membros, assignments, extras, tokens e o código do grupo; só as funções são trocadas.

Não existem arquivos de migração no repositório de propósito. Eles congelam uma cópia das funções
que envelhece: as três que existiam foram apagadas justamente porque, rodadas hoje, **desfariam**
mudanças já aplicadas. O histórico delas continua no git, que é o lugar certo para isso.

A exceção que justificaria um arquivo separado é uma mudança que mexa em *dado* (backfill de coluna,
constraint nova sobre linhas existentes) — nenhuma precisou até hoje. Nesse caso, o arquivo cobre só
o passo de dados, e o `schema.sql` continua cuidando da estrutura.

### 3. Popular as tasks e definir o código do grupo

```bash
npm run seed        # carrega as tasks do task-list.json
npm run set-code    # gera um código de 6 caracteres e imprime UMA vez
```

O banco guarda só o hash bcrypt do código — anote na hora. Para escolher o código você mesmo:
`npm run set-code MEUCODIGO`.

### 4. Rodar

```bash
npm run dev
```

---

## Começar uma run nova

```bash
npm run reset -- --yes    # apaga membros, progresso e extras; mantém as tasks e o código
npm run set-code          # opcional: gera um código novo
```

O schema e o seed continuam de pé — é só o grupo entrar de novo.

---

## Atualizar a lista de tasks

Há duas formas, e as duas fazem exatamente a mesma coisa no banco: um `upsert` por `id` na tabela
`tasks`. A automática é a que roda no dia a dia; a manual continua valendo e é o plano B.

**Automática** — um Worker do Cloudflare busca o
[task-list.json do upstream](https://github.com/OSRS-Taskman/collection-log-master/blob/main/src/main/resources/com/collectionlogmaster/task-list.json)
todo dia e aplica sozinho. Ver [Sincronização automática](#sincronização-automática).

**Manual** — troque o [task-list.json](task-list.json) local e rode o seed, **com a run em
andamento**:

```bash
npm run seed
```

**O progresso não se perde.** O seed faz `upsert` por `id` só na tabela `tasks` — nunca toca em
`assignments` nem em `extra_assignments`. Quem já existe tem os campos atualizados no lugar, quem é
novo entra como pendente, e tudo o que o grupo concluiu continua concluído.

O que vale conferir antes:

- **Task nova em tier já fechado** volta o tier atual para trás — `current_tier_order()` é o menor
  tier com task não concluída, então uma `hard` nova reabre o `hard` mesmo com o grupo no `elite`.
  É o gating funcionando, não um bug.
- **Task que muda de tier** mantém a conclusão; ela só passa a contar na outra barra de progresso.
- **Mesmo `id` com nome novo** atualiza o texto em todas as telas, inclusive na lista de concluídas.
- **`id` que some do JSON não é apagado** — o seed nunca deleta. A task fica no pool para sempre. Se
  precisar tirar, é `delete` manual no Supabase, e antes dele o assignment daquela task (a FK
  `assignments.task_id` segura).

O total ("X de Y tasks concluídas") vem do banco, via `task_total` no `get_state` e no
`list_completed`, então não há número para ajustar no código.

---

## Sincronização automática

Um Worker com Cron Trigger busca o `task-list.json` do upstream todo dia às **09:00 UTC** (06:00 em
Brasília, antes de o grupo jogar) e manda para a RPC `sync_tasks`. Tasks novas entram no pool
sozinhas.

É um **deploy separado do site**: o Cloudflare Pages não tem Cron Triggers, isso é do Workers.

```bash
npm run set-sync-secret       # gera o segredo e guarda o hash no banco
npx wrangler secret put SUPABASE_URL
npx wrangler secret put SUPABASE_ANON_KEY
npx wrangler secret put SYNC_SECRET    # o mesmo valor impresso acima
npm run worker:deploy
```

O horário está em [wrangler.toml](wrangler.toml) (`crons = ["0 9 * * *"]`); o código é o
[worker/index.ts](worker/index.ts).

### Por que um segredo próprio, e não a service_role key

A `service_role` ignora a RLS: um Worker comprometido leria a tabela `members`, pegaria os tokens e
viraria qualquer pessoa do grupo. O `SYNC_SECRET` só abre a `sync_tasks`, que só faz `upsert` em
`tasks` — não lê membros, não toca em `assignments`, não conclui nada. O banco guarda só o hash
bcrypt dele, no `group_state`, igual ao código do grupo.

### O que a `sync_tasks` recusa

| erro | quando |
|---|---|
| `INVALID_SYNC_SECRET` | segredo errado |
| `SYNC_NOT_CONFIGURED` | `npm run set-sync-secret` nunca rodou |
| `SYNC_BAD_PAYLOAD` | o corpo não é um array |
| `SYNC_SHRANK` | o upstream veio **menor** que o banco — commit ruim lá em cima ou download truncado |
| `SYNC_DUPLICATE_IDS` | dois ids iguais no mesmo payload |

A guarda de encolhimento existe porque o `upsert` nunca deleta: um JSON pela metade não apagaria
nada, mas passaria despercebido no log como se fosse um dia normal.

### Acompanhar e disparar na mão

```bash
npm run worker:log    # wrangler tail — {"inserted":N,"updated":N,"total":N,"tier_before":N,"tier_after":N,"discord":"…"}
export SYNC_SECRET='…'   # o valor que o `npm run set-sync-secret` imprimiu
curl -X POST https://<worker>.workers.dev -H "authorization: Bearer $SYNC_SECRET"
```

O `curl` dispara na hora, sem esperar o cron — útil logo depois do deploy, para saber se funcionou.
O `$SYNC_SECRET` é uma variável do **seu terminal**: ele não está no `.env.local` e nem o Cloudflare
nem o banco devolvem o valor. Sem o `export`, o header vai vazio e o Worker responde
`nao autorizado`. Perdeu o valor? Gere outro com `npm run set-sync-secret` e mande o mesmo para o
Worker com `npx wrangler secret put SYNC_SECRET` — os dois lados precisam bater.

⚠️ Vale a ressalva do gating: se o upstream adicionar uma task de um tier que o grupo **já fechou**,
o tier atual volta para trás sozinho, de madrugada. É o comportamento correto do jogo, mas
surpreende — por isso o aviso no Discord destaca esse caso.

### Aviso no Discord

Quando a sincronização traz task nova, o Worker posta num canal do Discord via **webhook** (não é um
bot: o webhook é só uma URL que aceita um POST). A mensagem traz quantas tasks entraram e um card por
task — nome com link da wiki, dica, imagem e a cor do tier. Se alguma delas reabrir um tier que o
grupo já tinha fechado, a mensagem avisa que o tier atual voltou (ex.: de **Hard** para **Easy**).

```bash
# Discord: Configurações do canal → Integrações → Webhooks → Novo webhook → Copiar URL
npx wrangler secret put DISCORD_WEBHOOK_URL
npm run worker:deploy
curl -X POST https://<worker>.workers.dev/discord-teste -H "authorization: Bearer $SYNC_SECRET"
```

O `/discord-teste` manda um aviso de exemplo (duas tasks do upstream, marcado como teste) sem mexer
no banco — é o jeito de ver a mensagem sem esperar entrar task nova.

- **Sem o segredo, nada muda:** o Worker só sincroniza, como antes.
- **Falha do Discord não derruba o sync.** Quando o aviso sai, as tasks já estão no banco; o erro vai
  para o log (`"discord":"falhou: …"`) e o cron conta como sucesso. O aviso perdido não volta — no
  dia seguinte a task já não é nova.
- **Banco vazio não avisa.** Na primeira carga (ou depois de um reset) seriam as ~1000 tasks de uma
  vez; o Worker reconhece o caso e fica quieto.
- **Até 10 cards por mensagem** (limite do Discord). Passou disso, a mensagem diz quantas foram e
  mostra as 10 primeiras, dos tiers mais baixos para os mais altos.
- **O `npm run seed` manual não avisa** — ele grava direto na tabela, sem passar pelo Worker.
- A URL do webhook é um segredo: quem tiver ela posta no canal. Se vazar, apague o webhook no
  Discord e crie outro.

---

## Deploy (Cloudflare Pages)

| Campo | Valor |
|---|---|
| Framework preset | None |
| Build command | `npm run build` |
| Output directory | `dist` |
| Variáveis | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` |

As duas variáveis precisam existir **no momento do build** — o Vite as injeta no bundle, então sem
elas o site sobe e quebra ao abrir. Não coloque a `service_role` / secret key ali: ela ignora a RLS e
só é usada pelos scripts locais.

O [public/_redirects](public/_redirects) cuida do fallback de SPA para `/board`, `/completed` e
`/pending`, e o
[.node-version](.node-version) fixa o Node 24 no build.

> O build image v3 do Pages **ignora** o campo `engines` do `package.json` — `.node-version`,
> `.nvmrc` ou a variável `NODE_VERSION` são as únicas formas de fixar a versão. O `24.18.0` é uma das
> versões já pré-instaladas na imagem, então o pin não custa download no build.

---

## Verificação

```bash
npm run typecheck
npm run build
npm run verify -- --yes-destructive   # roda as regras contra o banco de verdade
```

O `verify` usa o mesmo `supabase-js` do front e cobre 40 checagens: login e limite de 5 pessoas,
isolamento por usuário (rolar com o token de A não dá task para mais ninguém), 5 rolls **em paralelo**
resultando em 5 tasks distintas, dois membros com tasks de mesmo *nome* sendo aceitos, `TIER_LOCKED`
quando as easy restantes já estão todas ativas, a virada para medium exatamente na 179ª, a lista de
pendentes com filtro e busca, a conclusão manual (`TASK_TAKEN` / `ALREADY_COMPLETED`) e o bloqueio da
RLS para a anon key.

⚠️ Ele **apaga membros, assignments e tasks extra** — rode antes da run começar pra valer. A tabela
`tasks` não é tocada.

Há também uma suíte que roda direto no Postgres, sem precisar do Supabase — útil para mexer no
schema ([supabase/tests/](supabase/tests/)):

```bash
docker run -d --name pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=tasklocked -p 55432:5432 postgres:16-alpine
psql ... -f supabase/schema.sql
psql ... -f supabase/tests/rules.sql        # 48 asserções sequenciais
psql ... -f supabase/tests/extra-tasks.sql  # 57 asserções das tasks extra e da /completed
psql ... -f supabase/tests/sync-tasks.sql   # 10 asserções do que o worker avisa no Discord
bash supabase/tests/concurrency.sh          # 20 conexões paralelas disputando o pool
```

A suíte `extra-tasks.sql` cobre quem pode pegar uma extra, o limite de uma por pessoa (checando o
erro **e** o índice único no insert cru), o contador de `/completed` subindo a cada conclusão, a
garantia de que `assignments` e o `completed_total` não se mexem, o `completions` com nome/data/flag
de cada pessoa, o `abandon_extra_task` (que o site não expõe, mas o banco ainda oferece), os
filtros da `/completed` (busca, "já fiz / não fiz" e "feitas por", combinados e paginados) e o
cascade quando um membro sai do grupo.

### Teste manual

Abra 3 janelas anônimas e entre com o mesmo código e nomes diferentes. Clique em "Gerar task" **em
uma janela só** e confirme que apenas aquele membro ganhou task. Gere nas três e confirme que as
tasks são diferentes e aparecem umas para as outras em até 3s. Conclua uma (a confirmação aparece
antes) e veja ela sumir do board e aparecer em `/completed` para todas. Em `/pending`, confirme que a
task ativa de outra janela aparece com o nome do dono e o botão "Completar" desativado.

---

## Estrutura

```
src/
  lib/          supabase · types · api (RPCs tipadas + erros em português) · session · format
  hooks/        useGroupState — polling de 3s
  components/   MyTaskCard · ExtraTaskCard · MemberCard (read-only) · ConfirmDialog · …
  pages/        LoginPage · BoardPage · CompletedPage · PendingPage
supabase/
  schema.sql    tabelas, índices, RLS e as funções — fonte da verdade, idempotente
  tests/        suítes SQL + teste de concorrência
worker/         index.ts — cron diário que sincroniza as tasks com o upstream
wrangler.toml   config do Worker (deploy separado do Pages)
scripts/        apply-schema · seed-tasks · set-code · set-sync-secret · reset · verify-rules
public/         _redirects · robots.txt · favicon.ico · apple-touch-icon.png · og.png
```

Os três ícones em `public/` são recortes quadrados da `logo.jpeg` da raiz (que fica como fonte).
Para trocar a logo: substitua o arquivo e gere de novo o `favicon.ico` (16/32/48), o
`apple-touch-icon.png` (180×180) e o `og.png` (1200×630, logo centralizada sobre `--color-bg`).

Restyle: as cores estão todas em variáveis no topo de [src/index.css](src/index.css).

---

## Notas

- **Nomes de task repetidos:** o dataset tem 161 pares (tier, nome) duplicados — ex.: "Get 1 unique
  from Wintertodt" aparece 5× no easy. São tasks distintas e progressivas, e duas pessoas **podem**
  ficar com o mesmo texto na tela ao mesmo tempo: o único bloqueio é por `task_id`.
- **Concluir pela lista `/pending`:** marca a task como concluída em nome de quem clicou, mesmo sem
  ela ter sido sorteada — é o jeito de registrar o que o grupo já fez no jogo. Duas ressalvas: ali
  **não há gating de tier** (dá para fechar uma master com o grupo ainda no easy), e a task ativa de
  outra pessoa continua fora do alcance (`TASK_TAKEN`).
- **Extra + `undo_complete`:** desfazer uma conclusão devolve a task ao pool, mas não mexe em quem
  já a tinha pego de extra — a extra continua no board daquela pessoa e some de `/completed` até a
  task ser concluída de novo. É uma janela de 10 minutos e o efeito é cosmético: quando a task for
  concluída de novo, a linha volta e a extra segue valendo.
- **Sem skip:** se alguém pegar uma task inviável, ela trava para o grupo. Para devolvê-la ao pool,
  apague o assignment no dashboard do Supabase.
- **Fora da busca:** o `index.html` tem `<meta name="robots" content="noindex">` — é uma ferramenta
  privada de grupo. O [public/robots.txt](public/robots.txt) **não** bloqueia o crawl de propósito:
  bloquear seria mais fraco, porque o robô nunca leria a `noindex` e a URL ainda poderia aparecer na
  busca via link de terceiro.
- **Preview de link:** as tags Open Graph do `index.html` apontam para `https://rs-tasklocked.pages.dev`
  em **URL absoluta** — boa parte dos unfurlers ignora caminho relativo. Se o domínio mudar (domínio
  próprio, outro projeto no Pages), o `og:url` e o `og:image` precisam ser atualizados junto.
- **Free tier pausa após 7 dias sem uso.** Um GitHub Action semanal batendo na API resolve.
- **179 easy** = ~36 por pessoa antes de ver medium. Se cansar, o ajuste é só no `having` do passo 3
  do `roll_task`.
