-- =============================================================================
-- rs_tasklocked — schema completo
--
-- Rode este arquivo inteiro no SQL Editor do Supabase (ou via psql). E
-- idempotente: pode rodar de novo sem quebrar nada (nao apaga dados).
--
-- Regras do jogo que este schema garante:
--   1. Gerar/concluir sao acoes individuais (as funcoes so recebem o token do
--      proprio membro, nunca um member_id de terceiro).
--   2. Duas pessoas nunca tem a MESMA task (mesmo task_id). Tasks de NOME igual
--      e id diferente sao permitidas — o dataset tem 161 pares repetidos.
--   3. Task concluida sai do pool do grupo para sempre.
--   4. Tiers sao sequenciais: todas as easy antes de qualquer medium, etc.
-- =============================================================================

-- No Supabase o pgcrypto ja vem instalado no schema `extensions`, e este
-- comando vira um no-op. Por isso todas as funcoes abaixo usam
-- `search_path = public, extensions`: sem isso o crypt()/gen_salt() do
-- codigo do grupo nao seria encontrado. Num Postgres puro o schema
-- `extensions` nao existe, e o Postgres simplesmente o ignora no search_path.
create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Tabelas
-- -----------------------------------------------------------------------------

create table if not exists tasks (
  id              uuid primary key,
  tier            text not null check (tier in ('easy','medium','hard','elite','master')),
  tier_order      int  not null check (tier_order between 1 and 5),
  name            text not null,
  short_name      text,
  tip             text not null,
  wiki_link       text not null,
  image_link      text not null,
  display_item_id int  not null,
  verification    jsonb,
  tags            text[]
);

create index if not exists tasks_tier_order_idx on tasks (tier_order);
create index if not exists tasks_name_idx       on tasks (name);

-- Grupo unico: o check no primary key garante que so existe UMA linha.
create table if not exists group_state (
  id          boolean primary key default true check (id),
  code_hash   text not null,
  max_members int  not null default 5,
  created_at  timestamptz not null default now()
);

-- Segredo do worker que sincroniza a lista de tasks com o upstream (ver
-- `sync_tasks` la embaixo). Fica aqui, e nao numa tabela nova, porque e a mesma
-- natureza do `code_hash`: uma senha do grupo, guardada so como hash bcrypt.
-- Nulo = a sincronizacao automatica nao foi configurada, e `sync_tasks` recusa.
alter table group_state add column if not exists sync_secret_hash text;

create table if not exists members (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  name_key     text not null unique,   -- lower(trim(name)): "Edu" e "edu" sao o mesmo membro
  token        uuid not null default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists members_token_idx on members (token);

create table if not exists assignments (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references members(id) on delete cascade,
  task_id      uuid not null references tasks(id),
  status       text not null default 'active' check (status in ('active','completed')),
  assigned_at  timestamptz not null default now(),
  completed_at timestamptz
);

-- Migracao: a regra de "nome unico entre as ativas" caiu. Duas pessoas podem
-- ficar com tasks de mesmo nome, desde que sejam ids diferentes. Some tudo o
-- que existia so para sustentar aquela regra (indice, trigger e a copia do
-- nome). Idempotente: nada acontece em um banco novo.
drop trigger  if exists assignments_fill_task_name_trg on assignments;
drop function if exists assignments_fill_task_name();
drop index    if exists assignments_active_name_unique;
alter table assignments drop column if exists task_name;

-- -----------------------------------------------------------------------------
-- Os dois indices que sustentam as regras do jogo.
-- Sao a garantia REAL: mesmo que a logica das funcoes tenha um bug, o Postgres
-- se recusa a gravar um estado invalido.
-- -----------------------------------------------------------------------------

-- Regra: no maximo UMA task ativa por membro.
create unique index if not exists assignments_one_active_per_member
  on assignments (member_id) where status = 'active';

-- Regra: uma task NUNCA e atribuida duas vezes (nem ativa, nem concluida).
-- E o unico bloqueio de duplicidade que sobrou: e por task_id, nao por nome.
create unique index if not exists assignments_task_unique
  on assignments (task_id);

create index if not exists assignments_completed_at_idx
  on assignments (completed_at desc) where status = 'completed';

-- -----------------------------------------------------------------------------
-- Tasks EXTRA: repetir uma task que o grupo JA concluiu.
--
-- Ficam numa tabela separada de propósito. Em `assignments` existe
-- `assignments_task_unique`, que garante que uma task nunca tem dois
-- assignments — e uma extra aponta justamente para uma task que ja tem o seu.
-- Guardar as extras a parte preserva aquele indice intacto: ele continua sendo
-- a garantia das regras do pool, que as extras nao afetam em nada (nao mudam o
-- tier atual nem o contador do pool).
-- -----------------------------------------------------------------------------

create table if not exists extra_assignments (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references members(id) on delete cascade,
  task_id      uuid not null references tasks(id),
  status       text not null default 'active' check (status in ('active','completed')),
  assigned_at  timestamptz not null default now(),
  completed_at timestamptz
);

-- No maximo UMA extra ativa por membro.
create unique index if not exists extra_assignments_one_active_per_member
  on extra_assignments (member_id) where status = 'active';

-- A mesma pessoa nunca pega a mesma task de extra duas vezes (vale para os dois
-- status). E o que faz o contador da /completed contar PESSOAS, nao repeticoes.
create unique index if not exists extra_assignments_member_task_unique
  on extra_assignments (member_id, task_id);

create index if not exists extra_assignments_task_idx
  on extra_assignments (task_id) where status = 'completed';

-- -----------------------------------------------------------------------------
-- Seguranca: RLS ligada SEM nenhuma policy => acesso direto negado para todos.
-- Todo acesso passa pelas funcoes security definer abaixo.
-- -----------------------------------------------------------------------------

alter table tasks             enable row level security;
alter table group_state       enable row level security;
alter table members           enable row level security;
alter table assignments       enable row level security;
alter table extra_assignments enable row level security;

revoke all on tasks, group_state, members, assignments, extra_assignments
  from anon, authenticated;

-- =============================================================================
-- Funcoes RPC
--
-- Erros usam codigos estaveis no formato "CODIGO" para o front traduzir:
--   INVALID_CODE · GROUP_FULL · INVALID_TOKEN · ALREADY_ACTIVE
--   NO_ACTIVE_TASK · TIER_LOCKED · ALL_DONE · UNDO_EXPIRED · NOT_INITIALIZED
--   TASK_NOT_FOUND · ALREADY_COMPLETED · TASK_TAKEN
--   NOT_COMPLETED_YET · EXTRA_ALREADY_ACTIVE · EXTRA_ALREADY_DONE · NO_EXTRA_TASK
--   EXTRA_OWN_TASK
-- =============================================================================

-- Resolve o token -> member_id. Toda funcao comeca por aqui: e o unico jeito
-- de identificar quem esta agindo, e ele so pode agir sobre si mesmo.
create or replace function auth_member(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid;
begin
  if p_token is null then
    raise exception 'INVALID_TOKEN';
  end if;

  select id into v_member_id from members where token = p_token;

  if v_member_id is null then
    raise exception 'INVALID_TOKEN';
  end if;

  update members set last_seen_at = now() where id = v_member_id;
  return v_member_id;
end;
$$;

-- Tier atual do grupo = menor tier_order que ainda tem task nao concluida.
-- Retorna null quando o grupo concluiu todas as tasks.
create or replace function current_tier_order()
returns int
language sql
stable
security definer
set search_path = public, extensions
as $$
  select t.tier_order
  from tasks t
  group by t.tier_order
  having count(*) > (
    select count(*)
    from assignments a
    join tasks t2 on t2.id = a.task_id
    where t2.tier_order = t.tier_order
      and a.status = 'completed'
  )
  order by t.tier_order
  limit 1;
$$;

-- -----------------------------------------------------------------------------
-- join_group: valida o codigo do grupo e devolve/cria o membro.
-- Se o nome ja existe, RETOMA aquele membro (quem limpou o localStorage volta
-- com o mesmo nome; o codigo do grupo ja e a senha).
-- -----------------------------------------------------------------------------
create or replace function join_group(p_code text, p_name text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_group    group_state%rowtype;
  v_name     text := trim(p_name);
  v_name_key text := lower(trim(p_name));
  v_member   members%rowtype;
  v_count    int;
begin
  select * into v_group from group_state where id = true;
  if not found then
    raise exception 'NOT_INITIALIZED';
  end if;

  if p_code is null or v_group.code_hash <> crypt(p_code, v_group.code_hash) then
    raise exception 'INVALID_CODE';
  end if;

  if v_name = '' or length(v_name) > 20 then
    raise exception 'INVALID_NAME';
  end if;

  select * into v_member from members where name_key = v_name_key;

  if not found then
    select count(*) into v_count from members;
    if v_count >= v_group.max_members then
      raise exception 'GROUP_FULL';
    end if;

    insert into members (name, name_key)
    values (v_name, v_name_key)
    returning * into v_member;
  end if;

  update members set last_seen_at = now() where id = v_member.id;

  return json_build_object(
    'member_id', v_member.id,
    'token',     v_member.token,
    'name',      v_member.name
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- get_state: payload unico que alimenta o board (chamado no polling de 3s).
-- -----------------------------------------------------------------------------
create or replace function get_state(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_tier      int  := current_tier_order();
begin
  return json_build_object(
    'me', v_member_id,

    'members', coalesce((
      select json_agg(m order by m.created_at)
      from (
        select
          mem.id,
          mem.name,
          mem.created_at,
          mem.last_seen_at,
          case when a.id is null then null else json_build_object(
            'assignment_id', a.id,
            'assigned_at',   a.assigned_at,
            'task',          to_jsonb(t) - 'tier_order'
          ) end as active,
          case when e.id is null then null else json_build_object(
            'assignment_id', e.id,
            'assigned_at',   e.assigned_at,
            'task',          to_jsonb(et) - 'tier_order'
          ) end as extra
        from members mem
        left join assignments a       on a.member_id = mem.id and a.status = 'active'
        left join tasks t             on t.id = a.task_id
        left join extra_assignments e on e.member_id = mem.id and e.status = 'active'
        left join tasks et            on et.id = e.task_id
      ) m
    ), '[]'::json),

    'current_tier', (select tier from tasks where tier_order = v_tier limit 1),

    'progress', coalesce((
      select json_agg(p order by p.tier_order)
      from (
        select
          t.tier,
          t.tier_order,
          count(*)::int as total,
          count(*) filter (where a.status = 'completed')::int as completed,
          count(*) filter (where a.status = 'active')::int    as active
        from tasks t
        left join assignments a on a.task_id = t.id
        group by t.tier, t.tier_order
      ) p
    ), '[]'::json),

    -- Continua sendo so o pool: as extras nao entram no total.
    'completed_total', (select count(*)::int from assignments where status = 'completed'),

    -- Denominador do progresso do grupo. Vem do banco de proposito, e nao de um
    -- numero fixo no front: o task-list.json muda de tamanho a cada atualizacao
    -- da lista do jogo, e um `npm run seed` novo ja deixa este valor correto
    -- sem tocar em codigo.
    'task_total', (select count(*)::int from tasks)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- roll_task: sorteia UMA task para o dono do token, e so para ele.
--
-- Nao existe parametro member_id: por construcao da API e impossivel sortear
-- para outra pessoa ou para o grupo inteiro.
-- -----------------------------------------------------------------------------
create or replace function roll_task(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_tier      int;
  v_task_id   uuid;
  v_task      tasks%rowtype;
  v_attempt   int := 0;
begin
  -- Serializa os sorteios do grupo: dois membros clicando no mesmo instante
  -- leem o pool antes de a outra transacao commitar e podem cair na MESMA task,
  -- gastando as retentativas abaixo a toa. Com 5 pessoas o custo e irrelevante:
  -- o sorteio leva microssegundos. Liberado automaticamente no commit.
  perform pg_advisory_xact_lock(hashtext('rs_tasklocked_roll'));

  if exists (select 1 from assignments where member_id = v_member_id and status = 'active') then
    raise exception 'ALREADY_ACTIVE';
  end if;

  v_tier := current_tier_order();
  if v_tier is null then
    raise exception 'ALL_DONE';
  end if;

  -- Retentativa: se dois membros sortearem a MESMA task no mesmo instante, o
  -- indice unico derruba um dos dois com unique_violation e ele sorteia de novo.
  loop
    v_attempt := v_attempt + 1;

    select t.id into v_task_id
    from tasks t
    where t.tier_order = v_tier
      -- nunca atribuida (nem ativa, nem concluida). O nome NAO entra aqui:
      -- duas pessoas podem ficar com tasks de mesmo nome e ids diferentes.
      and not exists (select 1 from assignments a where a.task_id = t.id)
    order by random()
    limit 1;

    if v_task_id is null then
      -- Sobraram tasks do tier, mas todas ja estao ativas com outras pessoas.
      -- Fiel a regra escolhida: nao adianta o tier seguinte, o membro espera.
      raise exception 'TIER_LOCKED';
    end if;

    begin
      insert into assignments (member_id, task_id) values (v_member_id, v_task_id);
      exit;
    exception when unique_violation then
      if v_attempt >= 3 then
        raise exception 'TIER_LOCKED';
      end if;
      v_task_id := null;
    end;
  end loop;

  select * into v_task from tasks where id = v_task_id;
  return (to_jsonb(v_task) - 'tier_order')::json;
end;
$$;

-- -----------------------------------------------------------------------------
-- complete_task: conclui a task ativa do dono do token, e so a dele.
-- -----------------------------------------------------------------------------
create or replace function complete_task(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_assignment_id uuid;
begin
  update assignments
  set status = 'completed', completed_at = now()
  where member_id = v_member_id and status = 'active'
  returning id into v_assignment_id;

  if v_assignment_id is null then
    raise exception 'NO_ACTIVE_TASK';
  end if;

  return json_build_object('assignment_id', v_assignment_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- undo_complete: desfaz a ultima conclusao PROPRIA se foi ha menos de 10 min e
-- o membro ainda nao sorteou outra. E correcao de clique errado, nao e skip.
-- -----------------------------------------------------------------------------
create or replace function undo_complete(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_assignment assignments%rowtype;
begin
  -- Mesmo lock do roll_task: garante que ninguem sorteie entre a checagem de
  -- "ja tem ativa" e o update que reativa a task.
  perform pg_advisory_xact_lock(hashtext('rs_tasklocked_roll'));

  if exists (select 1 from assignments where member_id = v_member_id and status = 'active') then
    raise exception 'ALREADY_ACTIVE';
  end if;

  select * into v_assignment
  from assignments
  where member_id = v_member_id and status = 'completed'
  order by completed_at desc
  limit 1;

  if not found then
    raise exception 'NO_ACTIVE_TASK';
  end if;

  if v_assignment.completed_at < now() - interval '10 minutes' then
    raise exception 'UNDO_EXPIRED';
  end if;

  update assignments
  set status = 'active', completed_at = null
  where id = v_assignment.id;

  return json_build_object('assignment_id', v_assignment.id);
end;
$$;

-- -----------------------------------------------------------------------------
-- list_completed: lista compartilhada do grupo, mais recentes primeiro.
--
-- Uma linha por task que saiu do pool. As extras NAO viram linha nova: elas
-- incrementam `completed_count`, o contador de quantas PESSOAS do grupo ja
-- fizeram aquela task (denominador = `member_total`, no topo do payload), e
-- entram em `completions` com o nome e a data de quem as fez.
--
-- Filtros opcionais, todos combinados com AND:
--   p_search     — pedaco do nome da task (mesmo ilike do list_pending)
--   p_done_by_me — true: so as que quem olha ja fez · false: so as que nao fez
--   p_done_by    — so as que ESSE membro ja fez
-- "Ja fez" vale tanto para quem tirou a task do pool quanto para quem concluiu
-- de extra. `total` continua sendo o do pool inteiro, sem filtro;
-- `match_total` e o que passou no filtro (e o que a paginacao usa).
-- -----------------------------------------------------------------------------

-- A assinatura ganhou parametros: sem o drop, o `create or replace` criaria uma
-- sobrecarga ao lado da antiga, e a chamada com 3 argumentos ficaria ambigua.
drop function if exists list_completed(uuid, int, int);

create or replace function list_completed(
  p_token      uuid,
  p_limit      int     default 50,
  p_offset     int     default 0,
  p_search     text    default null,
  p_done_by_me boolean default null,
  p_done_by    uuid    default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_limit     int  := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset    int  := greatest(coalesce(p_offset, 0), 0);
  v_search    text := nullif(trim(coalesce(p_search, '')), '');
begin
  return (
    -- As tasks que sairam do pool e passam no filtro, com `doers`: todo mundo
    -- que ja fez cada uma (quem tirou do pool + extras concluidas).
    with matching as (
      select a.id, a.task_id, a.member_id, a.completed_at, d.doers
      from assignments a
      join tasks t on t.id = a.task_id
      cross join lateral (
        select array_append(array(
          select e.member_id from extra_assignments e
          where e.task_id = a.task_id and e.status = 'completed'
        ), a.member_id) as doers
      ) d
      where a.status = 'completed'
        and (v_search     is null or t.name ilike '%' || v_search || '%')
        and (p_done_by_me is null or (v_member_id = any(d.doers)) = p_done_by_me)
        and (p_done_by    is null or p_done_by = any(d.doers))
    )
    select json_build_object(
      'total', (select count(*)::int from assignments where status = 'completed'),

      'match_total', (select count(*)::int from matching),

      -- Mesmo denominador do get_state: quantas tasks o pool tem hoje.
      'task_total', (select count(*)::int from tasks),

      'member_total', (select count(*)::int from members),

      -- Opcoes do filtro "feitas por".
      'members', coalesce((
        select json_agg(json_build_object('id', id, 'name', name) order by created_at)
        from members
      ), '[]'::json),

      -- Bloqueia pegar uma segunda extra sem precisar tentar e tomar erro.
      'has_active_extra', exists (
        select 1 from extra_assignments
        where member_id = v_member_id and status = 'active'
      ),

      'items', coalesce((
        select json_agg(x order by x.completed_at desc)
        from (
          select
            a.id,
            a.task_id,
            a.completed_at,
            mem.name as member_name,
            t.tier,
            t.name,
            t.short_name,
            t.wiki_link,
            t.image_link,
            t.display_item_id,

            -- 1 (quem tirou do pool) + quantas extras ja concluidas.
            1 + (
              select count(*)
              from extra_assignments e
              where e.task_id = a.task_id and e.status = 'completed'
            )::int as completed_count,

            -- Toda conclusao daquela task: [{ name, completed_at, extra }], em
            -- ordem cronologica.
            --
            -- Quem tirou a task do pool NAO vem necessariamente primeiro: desde
            -- que `take_extra_task` aceita a task ativa de outra pessoa, uma
            -- extra pode ser concluida antes de a task sair do pool. Por isso a
            -- lista e ordenada de fato, em vez de assumir a ordem.
            (
              select coalesce(jsonb_agg(
                jsonb_build_object(
                  'name',         c.name,
                  'completed_at', c.completed_at,
                  'extra',        c.extra
                ) order by c.completed_at
              ), '[]'::jsonb)
              from (
                select mem.name as name, a.completed_at as completed_at, false as extra
                union all
                select m2.name, e.completed_at, true
                from extra_assignments e
                join members m2 on m2.id = e.member_id
                where e.task_id = a.task_id and e.status = 'completed'
              ) c
            ) as completions,

            v_member_id = any(a.doers) as done_by_me,

            exists (
              select 1 from extra_assignments e
              where e.task_id = a.task_id
                and e.member_id = v_member_id
                and e.status = 'active'
            ) as extra_active

          from matching a
          join members mem on mem.id = a.member_id
          join tasks t     on t.id = a.task_id
          order by a.completed_at desc
          limit v_limit offset v_offset
        ) x
      ), '[]'::json)
    )
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- list_pending: todas as tasks que o grupo AINDA NAO concluiu, de todos os
-- tiers, com filtro opcional por tier e por texto do nome.
--
-- Diferente do roll_task, aqui nao ha gating de tier: e uma lista de consulta,
-- e a tela deixa concluir manualmente qualquer uma (ver complete_task_by_id).
-- `taken` marca as que estao ativas com alguem agora.
--
-- `extra_active`/`extra_done` dizem se quem esta olhando ja pegou aquela task
-- de extra: a tela oferece "pegar extra" nas que estao com OUTRA pessoa, e
-- precisa saber quais ja estao na mao dela para nao oferecer de novo.
-- -----------------------------------------------------------------------------
create or replace function list_pending(
  p_token  uuid,
  p_limit  int  default 50,
  p_offset int  default 0,
  p_tier   text default null,
  p_search text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_limit  int  := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int  := greatest(coalesce(p_offset, 0), 0);
  v_tier   text := nullif(trim(coalesce(p_tier, '')), '');
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  return json_build_object(
    -- Bloqueia pegar uma segunda extra sem precisar tentar e tomar erro.
    'has_active_extra', exists (
      select 1 from extra_assignments
      where member_id = v_member_id and status = 'active'
    ),

    'total', (
      select count(*)::int
      from tasks t
      where not exists (
          select 1 from assignments a where a.task_id = t.id and a.status = 'completed'
        )
        and (v_tier   is null or t.tier = v_tier)
        and (v_search is null or t.name ilike '%' || v_search || '%')
    ),
    'items', coalesce((
      select json_agg(x order by x.tier_order, x.name, x.id)
      from (
        select
          t.id,
          t.tier,
          t.tier_order,
          t.name,
          t.short_name,
          t.tip,
          t.wiki_link,
          t.image_link,
          t.display_item_id,
          (a.id is not null) as taken,
          mem.name           as holder_name,
          -- `extra_assignments_member_task_unique` garante no maximo uma linha
          -- por (membro, task), entao este join nao duplica a lista.
          coalesce(ex.status = 'active', false)    as extra_active,
          coalesce(ex.status = 'completed', false) as extra_done
        from tasks t
        left join assignments a on a.task_id = t.id and a.status = 'active'
        left join members mem   on mem.id = a.member_id
        left join extra_assignments ex
          on ex.task_id = t.id and ex.member_id = v_member_id
        where not exists (
            select 1 from assignments c where c.task_id = t.id and c.status = 'completed'
          )
          and (v_tier   is null or t.tier = v_tier)
          and (v_search is null or t.name ilike '%' || v_search || '%')
        order by t.tier_order, t.name, t.id
        limit v_limit offset v_offset
      ) x
    ), '[]'::json)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- complete_task_by_id: conclui uma task escolhida na lista de pendentes, sem
-- precisar sorteia-la antes. Serve para registrar o que ja foi feito no jogo.
--
-- Sem task atribuida  -> cria o assignment ja concluido em nome de quem chamou.
-- Ativa com quem chamou -> conclui (mesmo efeito do complete_task).
-- Ativa com OUTRA pessoa -> TASK_TAKEN. Concluir a task de outro membro
--   continua fora do alcance da API, como no resto do app.
-- -----------------------------------------------------------------------------
create or replace function complete_task_by_id(p_token uuid, p_task_id uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id  uuid := auth_member(p_token);
  v_assignment assignments%rowtype;
  v_new_id     uuid;
begin
  -- Mesmo lock do roll_task: sem ele, alguem pode sortear esta task entre a
  -- leitura abaixo e o insert, e o insert morreria com unique_violation crua.
  perform pg_advisory_xact_lock(hashtext('rs_tasklocked_roll'));

  if p_task_id is null or not exists (select 1 from tasks where id = p_task_id) then
    raise exception 'TASK_NOT_FOUND';
  end if;

  select * into v_assignment from assignments where task_id = p_task_id;

  if not found then
    insert into assignments (member_id, task_id, status, completed_at)
    values (v_member_id, p_task_id, 'completed', now())
    returning id into v_new_id;

    return json_build_object('assignment_id', v_new_id);
  end if;

  if v_assignment.status = 'completed' then
    raise exception 'ALREADY_COMPLETED';
  end if;

  if v_assignment.member_id <> v_member_id then
    raise exception 'TASK_TAKEN';
  end if;

  update assignments
  set status = 'completed', completed_at = now()
  where id = v_assignment.id;

  return json_build_object('assignment_id', v_assignment.id);
end;
$$;

-- =============================================================================
-- Tasks EXTRA
--
-- Um membro escolhe uma task que JA TEM DONO no pool — concluida pelo grupo, ou
-- ativa com outra pessoa — e a pega como "extra", ao lado da task normal. A
-- extra nao mexe no pool: nao entra em `assignments`, nao muda o tier atual,
-- nao muda o contador do pool. Ela so incrementa o contador de PESSOAS por task
-- que a /completed mostra.
--
-- Regras:
--   1. Varias pessoas PODEM estar com a mesma extra ao mesmo tempo — a
--      exclusividade que o pool protege e a do `assignments`, e a extra nao
--      entra la.
--   2. No maximo UMA extra ATIVA por membro. Nao vale para o registro direto
--      (ver complete_extra_by_id): esse nunca passa pelo estado ativo.
--   3. A mesma pessoa nunca faz a mesma task duas vezes: nem quem a concluiu no
--      pool pode pega-la de extra, nem da para repetir uma extra ja feita.
--   4. Uma task LIVRE nunca vale como extra — seria um atalho para furar o
--      gating de tier do roll_task.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- take_extra_task: pega como extra uma task que ja tem dono no pool.
--
-- Vale tanto para o que o grupo ja concluiu quanto para a task ATIVA de outra
-- pessoa: quem quer acompanhar alguem nao precisa esperar aquela pessoa
-- concluir. O que nunca vale e uma task livre (regra 4) ou a sua propria.
--
-- Sempre para o dono do token — como no resto da API, nao ha parametro
-- member_id, entao e impossivel pegar uma extra em nome de outra pessoa.
-- -----------------------------------------------------------------------------
create or replace function take_extra_task(p_token uuid, p_task_id uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_owner_id  uuid;
  v_status    text;
  v_task      tasks%rowtype;
  v_extra_id  uuid;
  v_at        timestamptz;
begin
  if p_task_id is null or not exists (select 1 from tasks where id = p_task_id) then
    raise exception 'TASK_NOT_FOUND';
  end if;

  -- `assignments_task_unique` garante no maximo uma linha por task, entao este
  -- select nunca traz mais de uma. Sem linha = task livre (regra 4).
  select a.member_id, a.status into v_owner_id, v_status
  from assignments a
  where a.task_id = p_task_id;

  if not found then
    raise exception 'NOT_COMPLETED_YET';
  end if;

  -- Regra 3, parte 1: quem concluiu a task no pool ja a fez. E se ela esta
  -- ativa comigo, e a minha task principal — pegar de extra nao faz sentido.
  if v_owner_id = v_member_id then
    if v_status = 'completed' then
      raise exception 'EXTRA_ALREADY_DONE';
    end if;
    raise exception 'EXTRA_OWN_TASK';
  end if;

  -- Regra 3, parte 2: e ninguem repete uma extra que ja pegou.
  if exists (
    select 1 from extra_assignments
    where member_id = v_member_id and task_id = p_task_id
  ) then
    raise exception 'EXTRA_ALREADY_DONE';
  end if;

  -- Regra 2. Checado aqui para dar mensagem boa; o indice unico e a garantia.
  if exists (
    select 1 from extra_assignments
    where member_id = v_member_id and status = 'active'
  ) then
    raise exception 'EXTRA_ALREADY_ACTIVE';
  end if;

  insert into extra_assignments (member_id, task_id)
  values (v_member_id, p_task_id)
  returning id, assigned_at into v_extra_id, v_at;

  select * into v_task from tasks where id = p_task_id;

  return json_build_object(
    'assignment_id', v_extra_id,
    'assigned_at',   v_at,
    'task',          to_jsonb(v_task) - 'tier_order'
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- complete_extra_task: conclui a extra ativa do dono do token.
--
-- Nao mexe em `assignments`: a task ja estava concluida pelo grupo e continua
-- contando UMA vez no pool. O efeito visivel e o contador de pessoas na
-- /completed subir de n para n+1.
-- -----------------------------------------------------------------------------
create or replace function complete_extra_task(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_extra_id  uuid;
begin
  update extra_assignments
  set status = 'completed', completed_at = now()
  where member_id = v_member_id and status = 'active'
  returning id into v_extra_id;

  if v_extra_id is null then
    raise exception 'NO_EXTRA_TASK';
  end if;

  return json_build_object('assignment_id', v_extra_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- complete_extra_by_id: registra que voce fez uma task, sem pegar extra antes.
--
-- Existe porque a regra 2 (uma extra ativa por vez) estava bloqueando o
-- registro do que ja aconteceu: quem conclui de passagem uma task que outra
-- pessoa ja tinha feito nao conseguia marca-la enquanto estivesse com uma
-- extra na mao. Aqui a linha nasce ja `completed`, entao nunca disputa o
-- indice `extra_assignments_one_active_per_member` — a regra 2 continua
-- valendo para o fluxo de pegar e fazer, e so nao se aplica ao registro.
--
-- Elegibilidade e a mesma do take_extra_task (a task precisa ter dono no pool),
-- e as regras 3 e 4 valem igual: ninguem registra a mesma task duas vezes, nem
-- registra uma task livre.
--
-- Se a task JA e a sua extra ativa, isto conclui aquela extra — e o mesmo
-- efeito do complete_extra_task, so que escolhendo qual.
-- -----------------------------------------------------------------------------
create or replace function complete_extra_by_id(p_token uuid, p_task_id uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_owner_id  uuid;
  v_status    text;
  v_extra     extra_assignments%rowtype;
  v_extra_id  uuid;
begin
  if p_task_id is null or not exists (select 1 from tasks where id = p_task_id) then
    raise exception 'TASK_NOT_FOUND';
  end if;

  select a.member_id, a.status into v_owner_id, v_status
  from assignments a
  where a.task_id = p_task_id;

  if not found then
    raise exception 'NOT_COMPLETED_YET';
  end if;

  if v_owner_id = v_member_id then
    if v_status = 'completed' then
      raise exception 'EXTRA_ALREADY_DONE';
    end if;
    raise exception 'EXTRA_OWN_TASK';
  end if;

  select * into v_extra
  from extra_assignments
  where member_id = v_member_id and task_id = p_task_id;

  if found then
    if v_extra.status = 'completed' then
      raise exception 'EXTRA_ALREADY_DONE';
    end if;

    update extra_assignments
    set status = 'completed', completed_at = now()
    where id = v_extra.id;

    return json_build_object('assignment_id', v_extra.id);
  end if;

  insert into extra_assignments (member_id, task_id, status, completed_at)
  values (v_member_id, p_task_id, 'completed', now())
  returning id into v_extra_id;

  return json_build_object('assignment_id', v_extra_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- abandon_extra_task: devolve a extra ativa sem concluir.
--
-- Existe por causa da regra 3: sem isso, escolher a extra errada travaria
-- aquela pessoa para sempre — ela nao poderia pegar outra (regra 2) nem
-- desistir dessa. Apaga a linha, entao a task volta a ficar disponivel como
-- extra para ela no futuro. Nao registra nada em lugar nenhum.
-- -----------------------------------------------------------------------------
create or replace function abandon_extra_task(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_extra_id  uuid;
begin
  delete from extra_assignments
  where member_id = v_member_id and status = 'active'
  returning id into v_extra_id;

  if v_extra_id is null then
    raise exception 'NO_EXTRA_TASK';
  end if;

  return json_build_object('assignment_id', v_extra_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- set_group_code: define/troca o codigo do grupo (guardado como hash bcrypt).
-- Usada apenas pelo script local `npm run set-code`, com a service_role key.
-- NUNCA e concedida ao anon.
-- -----------------------------------------------------------------------------
create or replace function set_group_code(p_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into group_state (id, code_hash)
  values (true, crypt(p_code, gen_salt('bf')))
  on conflict (id) do update set code_hash = excluded.code_hash;
end;
$$;

-- =============================================================================
-- Sincronizacao automatica da lista de tasks
--
-- Um Cron Trigger do Cloudflare Workers busca o task-list.json do upstream
-- (github.com/OSRS-Taskman/collection-log-master) uma vez por dia e manda a
-- lista inteira para `sync_tasks`. E o mesmo efeito do `npm run seed`, so que
-- sem ninguem no teclado.
--
-- Por que uma RPC com segredo proprio, e nao a service_role key no worker:
-- a service_role ignora a RLS, entao um worker comprometido leria a tabela
-- `members` e viraria qualquer pessoa do grupo. Este segredo so consegue fazer
-- upsert em `tasks` — nao le membros, nao toca em assignments, nao conclui
-- nada. E o mesmo raciocinio do resto da API: cada credencial faz uma coisa so.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- set_sync_secret: define/troca o segredo do worker. Como o set_group_code,
-- e usada so por script local com a service_role key e NUNCA vai para o anon.
-- -----------------------------------------------------------------------------
create or replace function set_sync_secret(p_secret text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_secret is null or length(trim(p_secret)) < 16 then
    raise exception 'WEAK_SYNC_SECRET';
  end if;

  update group_state
  set sync_secret_hash = crypt(p_secret, gen_salt('bf'))
  where id = true;

  -- Sem linha em group_state o update acima nao faz nada e o worker ficaria
  -- recebendo SYNC_NOT_CONFIGURED sem explicacao. Melhor falar agora.
  if not found then
    raise exception 'NOT_INITIALIZED';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- sync_tasks: upsert da lista inteira, por id. E o `npm run seed` em SQL.
--
-- Recebe um array ja achatado, com `tier` e `tier_order` resolvidos pelo worker
-- — a mesma forma que o seed-tasks.ts monta. Devolve o que mudou, para o worker
-- registrar no log (e nao ficar invisivel o que rodou de madrugada).
--
-- Nao apaga nada: id que sumiu do upstream continua no pool, exatamente como no
-- seed manual. Tirar uma task do ar e decisao humana, nao de cron.
-- -----------------------------------------------------------------------------
create or replace function sync_tasks(p_secret text, p_tasks jsonb)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash     text;
  v_incoming int;
  v_current  int;
  v_dupes    int;
  v_inserted int;
  v_updated  int;
begin
  select sync_secret_hash into v_hash from group_state where id = true;

  if not found or v_hash is null then
    raise exception 'SYNC_NOT_CONFIGURED';
  end if;

  if p_secret is null or v_hash <> crypt(p_secret, v_hash) then
    raise exception 'INVALID_SYNC_SECRET';
  end if;

  if p_tasks is null or jsonb_typeof(p_tasks) <> 'array' then
    raise exception 'SYNC_BAD_PAYLOAD';
  end if;

  select count(*) into v_incoming from jsonb_array_elements(p_tasks);
  select count(*) into v_current  from tasks;

  -- Guarda: a lista do upstream so cresce. Se veio menor, e commit ruim la em
  -- cima ou download truncado — para tudo e deixa um humano olhar. Sem isto, um
  -- JSON pela metade nao apagaria nada (o upsert nunca deleta), mas passaria
  -- despercebido no log como se fosse um dia normal.
  if v_incoming < v_current then
    raise exception 'SYNC_SHRANK: upstream=% banco=%', v_incoming, v_current;
  end if;

  -- Id repetido faz o upsert morrer com "ON CONFLICT DO UPDATE command cannot
  -- affect row a second time" — que nao diz nada para quem le o log do cron as
  -- 6 da manha. Melhor falhar aqui, dizendo o que houve.
  select count(*) into v_dupes
  from (
    select t->>'id' as id
    from jsonb_array_elements(p_tasks) t
    group by 1 having count(*) > 1
  ) d;

  if v_dupes > 0 then
    raise exception 'SYNC_DUPLICATE_IDS: % id(s) repetidos no upstream', v_dupes;
  end if;

  with incoming as (
    select
      (t->>'id')::uuid             as id,
      t->>'tier'                   as tier,
      (t->>'tier_order')::int      as tier_order,
      t->>'name'                   as name,
      t->>'short_name'             as short_name,
      t->>'tip'                    as tip,
      t->>'wiki_link'              as wiki_link,
      t->>'image_link'             as image_link,
      (t->>'display_item_id')::int as display_item_id,
      -- `->` devolve o jsonb 'null' quando a chave existe com valor nulo, e SQL
      -- NULL quando ela nao existe. Os dois tem que virar NULL na coluna.
      nullif(t->'verification', 'null'::jsonb) as verification,
      case when jsonb_typeof(t->'tags') = 'array'
           then array(select jsonb_array_elements_text(t->'tags'))
           else null end          as tags
    from jsonb_array_elements(p_tasks) t
  ),
  upserted as (
    insert into tasks (id, tier, tier_order, name, short_name, tip, wiki_link,
                       image_link, display_item_id, verification, tags)
    select id, tier, tier_order, name, short_name, tip, wiki_link,
           image_link, display_item_id, verification, tags
    from incoming
    on conflict (id) do update set
      tier            = excluded.tier,
      tier_order      = excluded.tier_order,
      name            = excluded.name,
      short_name      = excluded.short_name,
      tip             = excluded.tip,
      wiki_link       = excluded.wiki_link,
      image_link      = excluded.image_link,
      display_item_id = excluded.display_item_id,
      verification    = excluded.verification,
      tags            = excluded.tags
    -- xmax = 0 identifica a linha que acabou de nascer; qualquer outro valor
    -- veio do caminho do `do update`.
    returning (xmax = 0) as inserted
  )
  select count(*) filter (where inserted)::int,
         count(*) filter (where not inserted)::int
    into v_inserted, v_updated
  from upserted;

  return json_build_object(
    'inserted', v_inserted,
    'updated',  v_updated,
    'total',    (select count(*)::int from tasks)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Permissoes: o anon so pode executar as RPCs publicas.
-- auth_member, current_tier_order, set_group_code e set_sync_secret sao
-- internas (nao expostas ao PostgREST para o anon).
--
-- `sync_tasks` e a excecao que confirma a regra: ela E concedida ao anon, mas
-- so anda com o segredo do worker, que nao esta no bundle do site.
-- -----------------------------------------------------------------------------

revoke all on function auth_member(uuid)      from anon, authenticated, public;
revoke all on function current_tier_order()   from anon, authenticated, public;
revoke all on function set_group_code(text)   from anon, authenticated, public;
revoke all on function set_sync_secret(text)  from anon, authenticated, public;
grant execute on function set_group_code(text)  to service_role;
grant execute on function set_sync_secret(text) to service_role;

grant execute on function sync_tasks(text, jsonb) to anon, authenticated;

grant execute on function join_group(text, text)          to anon, authenticated;
grant execute on function get_state(uuid)                 to anon, authenticated;
grant execute on function roll_task(uuid)                 to anon, authenticated;
grant execute on function complete_task(uuid)             to anon, authenticated;
grant execute on function undo_complete(uuid)             to anon, authenticated;
grant execute on function list_completed(uuid, int, int, text, boolean, uuid) to anon, authenticated;
grant execute on function complete_task_by_id(uuid, uuid) to anon, authenticated;
grant execute on function list_pending(uuid, int, int, text, text) to anon, authenticated;
grant execute on function take_extra_task(uuid, uuid)     to anon, authenticated;
grant execute on function complete_extra_task(uuid)       to anon, authenticated;
grant execute on function complete_extra_by_id(uuid, uuid) to anon, authenticated;
grant execute on function abandon_extra_task(uuid)        to anon, authenticated;

-- Faz o PostgREST recarregar o cache na hora, em vez de esperar o proximo ciclo.
notify pgrst, 'reload schema';

-- =============================================================================
-- Relatorio final. Se voce esta lendo o resultado deste select no SQL Editor,
-- o arquivo rodou ate o fim. Esperado: 5 tabelas, 4 indices unicos, 17 funcoes.
-- =============================================================================
select
  (select count(*) from information_schema.tables
    where table_schema = 'public'
      and table_name in ('tasks','members','assignments','group_state',
                         'extra_assignments'))                           as tabelas,
  (select count(*) from pg_indexes
    where schemaname = 'public'
      and indexname in ('assignments_one_active_per_member',
                        'assignments_task_unique',
                        'extra_assignments_one_active_per_member',
                        'extra_assignments_member_task_unique'))         as indices_unicos,
  (select count(*) from information_schema.routines
    where routine_schema = 'public'
      and routine_name in ('join_group','get_state','roll_task','complete_task',
                           'undo_complete','list_completed','list_pending',
                           'complete_task_by_id','set_group_code',
                           'auth_member','current_tier_order',
                           'take_extra_task','complete_extra_task',
                           'complete_extra_by_id',
                           'abandon_extra_task',
                           'set_sync_secret','sync_tasks'))              as funcoes,
  (select count(*) from tasks)                                           as tasks_carregadas;
