-- =============================================================================
-- rs_tasklocked — schema completo
--
-- Rode este arquivo inteiro no SQL Editor do Supabase (ou via psql). E
-- idempotente: pode rodar de novo sem quebrar nada (nao apaga dados).
--
-- Regras do jogo que este schema garante:
--   1. Gerar/concluir sao acoes individuais (as funcoes so recebem o token do
--      proprio membro, nunca um member_id de terceiro).
--   2. Duas pessoas nunca tem a mesma task ativa.
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
  -- Copia de tasks.name, preenchida por trigger. Existe so para sustentar o
  -- indice unico de nome abaixo (o dataset tem 161 pares tier+nome repetidos).
  task_name    text not null default '',
  status       text not null default 'active' check (status in ('active','completed')),
  assigned_at  timestamptz not null default now(),
  completed_at timestamptz
);

alter table assignments add column if not exists task_name text not null default '';

-- Mantem task_name em sincronia sem que nenhum insert precise lembrar dele.
create or replace function assignments_fill_task_name()
returns trigger language plpgsql as $$
begin
  select name into new.task_name from tasks where id = new.task_id;
  return new;
end;
$$;

drop trigger if exists assignments_fill_task_name_trg on assignments;
create trigger assignments_fill_task_name_trg
  before insert or update of task_id on assignments
  for each row execute function assignments_fill_task_name();

update assignments a set task_name = t.name
  from tasks t where t.id = a.task_id and a.task_name = '';

-- -----------------------------------------------------------------------------
-- Os dois indices que sustentam as regras do jogo.
-- Sao a garantia REAL: mesmo que a logica das funcoes tenha um bug, o Postgres
-- se recusa a gravar um estado invalido.
-- -----------------------------------------------------------------------------

-- Regra: no maximo UMA task ativa por membro.
create unique index if not exists assignments_one_active_per_member
  on assignments (member_id) where status = 'active';

-- Regra: uma task NUNCA e atribuida duas vezes (nem ativa, nem concluida).
create unique index if not exists assignments_task_unique
  on assignments (task_id);

-- Regra: dois membros nunca veem o MESMO TEXTO de task ao mesmo tempo.
-- O indice de task_id nao cobre isso: ha 161 pares (tier, nome) duplicados no
-- dataset, entao dois ids diferentes podem exibir exatamente a mesma frase.
create unique index if not exists assignments_active_name_unique
  on assignments (task_name) where status = 'active';

create index if not exists assignments_completed_at_idx
  on assignments (completed_at desc) where status = 'completed';

-- -----------------------------------------------------------------------------
-- Seguranca: RLS ligada SEM nenhuma policy => acesso direto negado para todos.
-- Todo acesso passa pelas funcoes security definer abaixo.
-- -----------------------------------------------------------------------------

alter table tasks       enable row level security;
alter table group_state enable row level security;
alter table members     enable row level security;
alter table assignments enable row level security;

revoke all on tasks, group_state, members, assignments from anon, authenticated;

-- =============================================================================
-- Funcoes RPC
--
-- Erros usam codigos estaveis no formato "CODIGO" para o front traduzir:
--   INVALID_CODE · GROUP_FULL · INVALID_TOKEN · ALREADY_ACTIVE
--   NO_ACTIVE_TASK · TIER_LOCKED · ALL_DONE · UNDO_EXPIRED · NOT_INITIALIZED
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
-- Retorna null quando o grupo concluiu as 990 tasks.
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
          ) end as active
        from members mem
        left join assignments a on a.member_id = mem.id and a.status = 'active'
        left join tasks t       on t.id = a.task_id
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

    'completed_total', (select count(*)::int from assignments where status = 'completed')
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
  -- Serializa os sorteios do grupo. Sem isso, dois membros clicando no mesmo
  -- instante leem o pool antes de a outra transacao commitar e podem escolher
  -- tasks diferentes com o MESMO nome (o indice de task_id nao pega isso).
  -- Com 5 pessoas o custo e irrelevante: o sorteio leva microssegundos.
  -- Liberado automaticamente no commit (xact lock).
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
      -- nunca atribuida (nem ativa, nem concluida)
      and not exists (select 1 from assignments a where a.task_id = t.id)
      -- e sem colidir com o NOME de uma task ativa: ha 161 pares (tier, nome)
      -- duplicados no dataset, e duas pessoas com o mesmo texto na tela pareceria bug
      and not exists (
        select 1
        from assignments a
        join tasks t2 on t2.id = a.task_id
        where a.status = 'active' and t2.name = t.name
      )
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
  -- Mesmo lock do roll_task: reativar uma task tambem mexe no conjunto de ativas.
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

  begin
    update assignments
    set status = 'active', completed_at = null
    where id = v_assignment.id;
  exception when unique_violation then
    -- outro membro esta com uma task de nome identico ativa agora
    raise exception 'NAME_TAKEN';
  end;

  return json_build_object('assignment_id', v_assignment.id);
end;
$$;

-- -----------------------------------------------------------------------------
-- list_completed: lista compartilhada do grupo, mais recentes primeiro.
-- -----------------------------------------------------------------------------
create or replace function list_completed(p_token uuid, p_limit int default 50, p_offset int default 0)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit  int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  perform auth_member(p_token);

  return json_build_object(
    'total', (select count(*)::int from assignments where status = 'completed'),
    'items', coalesce((
      select json_agg(x order by x.completed_at desc)
      from (
        select
          a.id,
          a.completed_at,
          mem.name as member_name,
          t.tier,
          t.name,
          t.short_name,
          t.wiki_link,
          t.image_link,
          t.display_item_id
        from assignments a
        join members mem on mem.id = a.member_id
        join tasks t     on t.id = a.task_id
        where a.status = 'completed'
        order by a.completed_at desc
        limit v_limit offset v_offset
      ) x
    ), '[]'::json)
  );
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

-- -----------------------------------------------------------------------------
-- Permissoes: o anon so pode executar as RPCs publicas.
-- auth_member, current_tier_order e set_group_code sao internas
-- (nao expostas ao PostgREST para o anon).
-- -----------------------------------------------------------------------------

revoke all on function auth_member(uuid)      from anon, authenticated, public;
revoke all on function current_tier_order()   from anon, authenticated, public;
revoke all on function set_group_code(text)   from anon, authenticated, public;
grant execute on function set_group_code(text) to service_role;

grant execute on function join_group(text, text)          to anon, authenticated;
grant execute on function get_state(uuid)                 to anon, authenticated;
grant execute on function roll_task(uuid)                 to anon, authenticated;
grant execute on function complete_task(uuid)             to anon, authenticated;
grant execute on function undo_complete(uuid)             to anon, authenticated;
grant execute on function list_completed(uuid, int, int)  to anon, authenticated;

-- Faz o PostgREST recarregar o cache na hora, em vez de esperar o proximo ciclo.
notify pgrst, 'reload schema';

-- =============================================================================
-- Relatorio final. Se voce esta lendo o resultado deste select no SQL Editor,
-- o arquivo rodou ate o fim. Esperado: 4 tabelas, 3 indices unicos, 9 funcoes.
-- =============================================================================
select
  (select count(*) from information_schema.tables
    where table_schema = 'public'
      and table_name in ('tasks','members','assignments','group_state')) as tabelas,
  (select count(*) from pg_indexes
    where schemaname = 'public'
      and indexname in ('assignments_one_active_per_member',
                        'assignments_task_unique',
                        'assignments_active_name_unique'))               as indices_unicos,
  (select count(*) from information_schema.routines
    where routine_schema = 'public'
      and routine_name in ('join_group','get_state','roll_task','complete_task',
                           'undo_complete','list_completed','set_group_code',
                           'auth_member','current_tier_order'))          as funcoes,
  (select count(*) from tasks)                                           as tasks_carregadas;
