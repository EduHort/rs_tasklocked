# Task Locked — OSRS

Randomizador de tasks de Old School RuneScape para um grupo de até 5 pessoas.
Cada um sorteia **a sua própria** task do pool compartilhado, faz no jogo e marca como concluída.

**Regras**

1. Gerar e concluir são ações individuais — não existe botão que sorteie para o grupo todo.
2. Duas pessoas nunca ficam com a **mesma task** (mesmo `id`). Tasks de *nome* igual e id diferente
   são permitidas: o dataset tem 161 pares repetidos e eles são tasks distintas e progressivas.
3. Task concluída sai do pool do grupo para sempre.
4. Tiers são sequenciais **no sorteio**: as 179 `easy` precisam estar todas concluídas antes de
   qualquer `medium`, e assim por diante — 990 tasks no total.

**Telas:** `/board` (sua task + a do grupo) · `/completed` (o que já saiu) · `/pending` (todas as
tasks que faltam, com busca, filtro por tier e conclusão manual).

Stack: React + TypeScript + Tailwind (Vite) · Supabase (Postgres) · Cloudflare Pages.

---

## Como funciona

```
Browser (SPA)
   │  anon key — sem acesso direto a nenhuma tabela
   ▼
Supabase RPC   join_group · get_state · roll_task · complete_task · undo_complete
               list_completed · list_pending · complete_task_by_id
   ▼
Postgres  tasks · group_state · members · assignments
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

Copie o conteúdo de [supabase/schema.sql](supabase/schema.sql) e rode no **SQL Editor** do Supabase.
O arquivo é idempotente: pode rodar de novo sem perder dados.

### 3. Popular as tasks e definir o código do grupo

```bash
npm run seed        # carrega as 990 tasks do task-list.json
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
npm run reset -- --yes    # apaga membros e progresso; mantém as 990 tasks e o código
npm run set-code          # opcional: gera um código novo
```

O schema e o seed continuam de pé — é só o grupo entrar de novo.

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
[.node-version](.node-version) fixa o Node 22 no build.

---

## Verificação

```bash
npm run typecheck
npm run build
npm run verify -- --yes-destructive   # roda as regras contra o banco de verdade
```

O `verify` usa o mesmo `supabase-js` do front e cobre 39 checagens: login e limite de 5 pessoas,
isolamento por usuário (rolar com o token de A não dá task para mais ninguém), 5 rolls **em paralelo**
resultando em 5 tasks distintas, dois membros com tasks de mesmo *nome* sendo aceitos, `TIER_LOCKED`
quando as easy restantes já estão todas ativas, a virada para medium exatamente na 179ª, a lista de
pendentes com filtro e busca, a conclusão manual (`TASK_TAKEN` / `ALREADY_COMPLETED`) e o bloqueio da
RLS para a anon key.

⚠️ Ele **apaga membros e assignments** — rode antes da run começar pra valer. As 990 tasks não são
tocadas.

Há também uma suíte que roda direto no Postgres, sem precisar do Supabase — útil para mexer no
schema ([supabase/tests/](supabase/tests/)):

```bash
docker run -d --name pg -e POSTGRES_PASSWORD=test -e POSTGRES_DB=tasklocked -p 55432:5432 postgres:16-alpine
psql ... -f supabase/schema.sql
psql ... -f supabase/tests/rules.sql        # 48 asserções sequenciais
bash supabase/tests/concurrency.sh          # 20 conexões paralelas disputando o pool
```

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
  components/   MyTaskCard · MemberCard (read-only) · ConfirmDialog · TierProgressBar · …
  pages/        LoginPage · BoardPage · CompletedPage · PendingPage
supabase/
  schema.sql    tabelas, índices, RLS e as 9 funções
  tests/        suíte SQL + teste de concorrência
scripts/        seed-tasks · set-code · verify-rules
```

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
- **Sem skip:** se alguém pegar uma task inviável, ela trava para o grupo. Para devolvê-la ao pool,
  apague o assignment no dashboard do Supabase.
- **Free tier pausa após 7 dias sem uso.** Um GitHub Action semanal batendo na API resolve.
- **179 easy** = ~36 por pessoa antes de ver medium. Se cansar, o ajuste é só no `having` do passo 3
  do `roll_task`.
