-- =============================================================================
-- Migracao: task_total — o tamanho do pool sai do banco, nao do codigo
--
-- Rode no SQL Editor do Supabase, DEPOIS da migration-completions-detail.sql.
--
-- Substitui duas funcoes (`get_state` e `list_completed`) por
-- `create or replace`. Nao cria, altera nem apaga tabela nenhuma — nao ha dado
-- envolvido, e rodar de novo nao faz diferenca.
--
-- Por que existe: o front tinha 990 escrito na mao como denominador ("X de
-- 990"). Esse numero e o tamanho do task-list.json, e ele muda quando a lista
-- do jogo e atualizada — a versao de agosto/2026, por exemplo, foi de 990 para
-- 997 tasks. Com o total vindo do banco, um `npm run seed` novo ja acerta a
-- tela sozinho.
--
-- O que muda no JSON:
--   get_state       + task_total  — quantas tasks a tabela `tasks` tem hoje
--   list_completed  + task_total  — o mesmo numero, para a /completed
--
-- Nenhum campo sai, entao o front antigo continua funcionando no intervalo
-- entre este SQL e o deploy: ele so ignora o campo novo.
-- =============================================================================

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

    -- Mesmo denominador do get_state: quantas tasks o pool tem hoje.
    'task_total', (select count(*)::int from tasks),

    'member_total', (select count(*)::int from members),

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

-- Faz o PostgREST recarregar o cache na hora, em vez de esperar o proximo ciclo.
notify pgrst, 'reload schema';

-- =============================================================================
-- Relatorio: o tamanho do pool e a confirmacao de que as duas funcoes ficaram
-- com o campo novo. Esperado: `ambas_com_task_total` = 2.
--
-- A checagem le o texto das funcoes em vez de chama-las: `get_state` e
-- `list_completed` exigem um token valido (INVALID_TOKEN sem membro) e passam
-- por `auth_member`, que escreve em `members.last_seen_at`. Como o SQL Editor
-- roda o script inteiro numa transacao, um erro aqui reverteria a troca das
-- funcoes acima — um relatorio somente-leitura nao corre esse risco.
-- =============================================================================
select
  (select count(*) from tasks)                                  as tasks_no_pool,
  (select count(*) from assignments where status = 'completed') as concluidas,
  (select count(*) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('get_state', 'list_completed')
     and pg_get_functiondef(p.oid) like '%task_total%')         as ambas_com_task_total;
