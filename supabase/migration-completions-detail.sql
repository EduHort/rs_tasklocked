-- =============================================================================
-- Migracao: detalhe das conclusoes na /completed
--
-- Rode no SQL Editor do Supabase, DEPOIS da migration-extra-tasks.sql.
--
-- Substitui uma unica funcao (`list_completed`) por `create or replace`.
-- Nao cria, altera nem apaga tabela nenhuma — nao ha dado envolvido.
-- Rodar de novo nao faz diferenca.
--
-- O que muda no JSON de cada item:
--   + completions  — array com TODA conclusao daquela task, em ordem:
--                    [{ name, completed_at, extra }], onde `extra` = false para
--                    quem tirou a task do pool e true para quem a repetiu.
--   - completed_by — sai; era so a string de nomes, que `completions` cobre
--                    com muito mais informacao.
--
-- `member_name` e `completed_at` continuam no item (sao a primeira conclusao,
-- a que tirou a task do pool) para o front antigo nao quebrar no intervalo
-- entre este SQL e o deploy.
-- =============================================================================

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

          -- Quem tirou a task do pool vem sempre primeiro: `take_extra_task` so
          -- deixa pegar o que ja esta concluido, entao nenhuma extra pode ter
          -- sido feita antes dela.
          jsonb_build_array(jsonb_build_object(
            'name',         mem.name,
            'completed_at', a.completed_at,
            'extra',        false
          )) || coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'name',         m2.name,
                'completed_at', e.completed_at,
                'extra',        true
              ) order by e.completed_at
            )
            from extra_assignments e
            join members m2 on m2.id = e.member_id
            where e.task_id = a.task_id and e.status = 'completed'
          ), '[]'::jsonb) as completions,

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

notify pgrst, 'reload schema';

-- =============================================================================
-- Relatorio: a primeira linha da /completed, ja no formato novo.
-- `completions` deve trazer um objeto por pessoa que fez a task.
--
-- O coalesce e proposital: sem nenhum membro cadastrado a funcao levantaria
-- INVALID_TOKEN, e como o SQL Editor roda o script inteiro numa transacao, o
-- erro reverteria a troca da funcao acima. Sem membros, sai zero linha.
-- =============================================================================
select
  x->>'name'                               as task,
  x->>'completed_count'                    as pessoas,
  jsonb_pretty((x->'completions')::jsonb)  as completions
from json_array_elements(
  coalesce(
    (select list_completed(m.token, 1, 0) from members m order by m.created_at limit 1),
    '{"items":[]}'::json
  )->'items'
) x;
