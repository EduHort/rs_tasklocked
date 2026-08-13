-- =============================================================================
-- Migracao: tasks EXTRA
--
-- Rode este arquivo inteiro no SQL Editor do Supabase. E idempotente e
-- ADITIVO: cria uma tabela nova, dois indices e tres funcoes, e substitui
-- get_state e list_completed por versoes que apenas ACRESCENTAM campos ao
-- JSON. Nenhum `alter`/`drop`/`delete` nas tabelas que ja estao no ar —
-- tasks, members, assignments e group_state nao sao tocadas.
--
-- Ordem segura de deploy: rode este SQL PRIMEIRO, depois publique o front.
-- O front antigo continua funcionando com o schema novo (ele so ignora os
-- campos a mais).
--
-- O que a feature faz:
--   Um membro escolhe uma task JA CONCLUIDA pelo grupo e a pega como "extra",
--   que fica ao lado da task normal dele. A extra nao mexe no pool das 990:
--   nao entra em `assignments`, nao muda o tier atual, nao muda o contador de
--   concluidas do grupo. Ela so incrementa o contador "quantas pessoas do
--   grupo ja fizeram esta task" que aparece na tela /completed.
--
-- Regras (decididas com o dono do projeto):
--   1. Varias pessoas PODEM estar com a mesma extra ao mesmo tempo — a task ja
--      saiu do pool, entao nao ha exclusividade a proteger.
--   2. No maximo UMA extra ativa por membro.
--   3. A mesma pessoa nunca faz a mesma task duas vezes: nem quem a concluiu
--      no pool pode pega-la de extra, nem da para repetir uma extra ja feita.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tabela
--
-- Por que uma tabela separada e nao mais uma linha em `assignments`: la existe
-- `assignments_task_unique`, que garante que uma task NUNCA tem dois
-- assignments. Uma extra aponta justamente para uma task que ja tem o seu, e
-- por isso o insert seria recusado. Guardar as extras a parte preserva aquele
-- indice intacto — ele continua sendo a garantia das regras do pool.
-- -----------------------------------------------------------------------------

create table if not exists extra_assignments (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references members(id) on delete cascade,
  task_id      uuid not null references tasks(id),
  status       text not null default 'active' check (status in ('active','completed')),
  assigned_at  timestamptz not null default now(),
  completed_at timestamptz
);

-- Regra 2: no maximo UMA extra ativa por membro.
create unique index if not exists extra_assignments_one_active_per_member
  on extra_assignments (member_id) where status = 'active';

-- Regra 3: a mesma pessoa nunca pega a mesma task de extra duas vezes.
-- Vale para os dois status: quem ja concluiu a extra nao a pega de novo.
-- E o que faz o contador da /completed contar PESSOAS, e nao repeticoes.
create unique index if not exists extra_assignments_member_task_unique
  on extra_assignments (member_id, task_id);

create index if not exists extra_assignments_task_idx
  on extra_assignments (task_id) where status = 'completed';

-- Mesma postura do resto do schema: RLS ligada sem policy => a anon key nao le
-- nem escreve nada direto. Tudo passa pelas funcoes security definer.
alter table extra_assignments enable row level security;
revoke all on extra_assignments from anon, authenticated;

-- =============================================================================
-- Funcoes novas
--
-- Codigos de erro novos, no mesmo formato dos existentes:
--   NOT_COMPLETED_YET · EXTRA_ALREADY_ACTIVE · EXTRA_ALREADY_DONE · NO_EXTRA_TASK
-- =============================================================================

-- -----------------------------------------------------------------------------
-- take_extra_task: pega uma task ja concluida pelo grupo como extra.
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
  v_task      tasks%rowtype;
  v_extra_id  uuid;
  v_at        timestamptz;
begin
  if p_task_id is null or not exists (select 1 from tasks where id = p_task_id) then
    raise exception 'TASK_NOT_FOUND';
  end if;

  -- So vale para o que o grupo JA concluiu: a extra e uma repetida, nunca um
  -- atalho para furar o gating de tier do roll_task.
  select a.member_id into v_owner_id
  from assignments a
  where a.task_id = p_task_id and a.status = 'completed';

  if not found then
    raise exception 'NOT_COMPLETED_YET';
  end if;

  -- Regra 3, parte 1: quem concluiu a task no pool ja a fez.
  if v_owner_id = v_member_id then
    raise exception 'EXTRA_ALREADY_DONE';
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
-- contando UMA vez nas 990. O efeito visivel e o contador de pessoas na
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

-- =============================================================================
-- Funcoes existentes, com campos NOVOS no JSON (assinatura inalterada).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- get_state: cada membro ganha `extra`, no mesmo formato de `active`
-- (null quando a pessoa nao esta com nenhuma extra).
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

    -- Continua sendo so o pool: as extras nao entram nas 990.
    'completed_total', (select count(*)::int from assignments where status = 'completed')
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- list_completed: mesma lista de sempre (uma linha por task que saiu do pool,
-- mais recentes primeiro), agora com o contador de PESSOAS por task.
--
-- Campos novos por item:
--   task_id         — para a tela poder pedir a extra
--   completed_count — 1 (quem tirou do pool) + quantas extras ja concluidas
--   completed_by    — os nomes, em ordem de conclusao, para o tooltip
--   done_by_me      — true se quem esta olhando ja fez essa task
--   extra_active    — true se ela e a extra ATIVA de quem esta olhando
-- No topo do payload:
--   member_total    — total de membros do grupo (o denominador do contador)
--   has_active_extra— true se quem olha ja esta com uma extra (bloqueia pegar outra)
-- -----------------------------------------------------------------------------
create or replace function list_completed(p_token uuid, p_limit int default 50, p_offset int default 0)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_member_id uuid := auth_member(p_token);
  v_limit     int  := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset    int  := greatest(coalesce(p_offset, 0), 0);
begin
  return json_build_object(
    'total', (select count(*)::int from assignments where status = 'completed'),

    'member_total', (select count(*)::int from members),

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

          1 + (
            select count(*)
            from extra_assignments e
            where e.task_id = a.task_id and e.status = 'completed'
          )::int as completed_count,

          -- "Edu, Ana, Joao" — quem tirou do pool primeiro, extras em seguida.
          mem.name || coalesce((
            select ', ' || string_agg(m2.name, ', ' order by e.completed_at)
            from extra_assignments e
            join members m2 on m2.id = e.member_id
            where e.task_id = a.task_id and e.status = 'completed'
          ), '') as completed_by,

          (
            a.member_id = v_member_id
            or exists (
              select 1 from extra_assignments e
              where e.task_id = a.task_id
                and e.member_id = v_member_id
                and e.status = 'completed'
            )
          ) as done_by_me,

          exists (
            select 1 from extra_assignments e
            where e.task_id = a.task_id
              and e.member_id = v_member_id
              and e.status = 'active'
          ) as extra_active

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
-- Permissoes das funcoes novas.
-- -----------------------------------------------------------------------------

grant execute on function take_extra_task(uuid, uuid)  to anon, authenticated;
grant execute on function complete_extra_task(uuid)    to anon, authenticated;
grant execute on function abandon_extra_task(uuid)     to anon, authenticated;

notify pgrst, 'reload schema';

-- =============================================================================
-- Relatorio. Esperado: 1 tabela, 2 indices unicos, 3 funcoes novas.
-- `extras_ativas` e `extras_concluidas` sao 0 num banco que nunca usou a
-- feature — se voce esta rodando de novo, elas mostram o que ja existe (e este
-- arquivo NAO apagou nada).
-- =============================================================================
select
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_name = 'extra_assignments')     as tabela,
  (select count(*) from pg_indexes
    where schemaname = 'public'
      and indexname in ('extra_assignments_one_active_per_member',
                        'extra_assignments_member_task_unique'))            as indices_unicos,
  (select count(*) from information_schema.routines
    where routine_schema = 'public'
      and routine_name in ('take_extra_task','complete_extra_task',
                           'abandon_extra_task'))                           as funcoes_novas,
  (select count(*) from extra_assignments where status = 'active')          as extras_ativas,
  (select count(*) from extra_assignments where status = 'completed')       as extras_concluidas,
  (select count(*) from assignments)                                        as assignments_intactos;
