-- =============================================================================
-- Suite da sync_tasks — o que o worker manda para o Discord. Roda direto no
-- Postgres, sem Supabase.
--
--   psql ... -f supabase/schema.sql
--   psql ... -f supabase/tests/sync-tasks.sql
--
-- Precisa da tabela `tasks` populada (o mesmo `npm run seed` das outras
-- suites). Roda INTEIRA numa transacao desfeita no fim: mexe em `tasks`, que as
-- outras suites nao tocam, e nao deixa rastro nenhum.
-- =============================================================================

\set ON_ERROR_STOP on
\pset pager off

begin;

create or replace function t_assert(p_label text, p_got text, p_want text) returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'FALHOU: % | esperado=% obtido=%', p_label, p_want, p_got;
  end if;
  raise notice 'ok   %  (%)', rpad(p_label, 56), p_got;
end $$;

truncate extra_assignments, assignments, members cascade;
delete from group_state;
select set_group_code('TESTE1');
select set_sync_secret('segredo-de-teste');

-- O payload do worker, montado a partir do que ja esta no banco.
create temp table payload as
select jsonb_agg(jsonb_build_object(
  'id', id, 'tier', tier, 'tier_order', tier_order, 'name', name,
  'short_name', short_name, 'tip', tip, 'wiki_link', wiki_link,
  'image_link', image_link, 'display_item_id', display_item_id,
  'verification', verification, 'tags', to_jsonb(tags)
)) as tasks
from tasks;

\echo '\n--- 1. nada novo ---'

select sync_tasks('segredo-de-teste', (select tasks from payload))::jsonb as r \gset
select t_assert('inserted = 0', :'r'::jsonb->>'inserted', '0');
select t_assert('new_tasks vazio', :'r'::jsonb->>'new_tasks', '[]');
select t_assert('tier nao muda',
  (:'r'::jsonb->>'tier_before') || '->' || (:'r'::jsonb->>'tier_after'), '1->1');

\echo '\n--- 2. task nova em tier ja fechado ---'

-- O grupo fecha o easy inteiro e passa para o medium.
insert into members (name, name_key) values ('Edu', 'edu');
insert into assignments (member_id, task_id, status, completed_at)
select (select id from members), id, 'completed', now() from tasks where tier = 'easy';

select sync_tasks('segredo-de-teste', (select tasks from payload) || jsonb_build_array(
  jsonb_build_object(
    'id', '00000000-0000-0000-0000-00000000e457', 'tier', 'easy', 'tier_order', 1,
    'name', 'Task nova de teste', 'short_name', null, 'tip', 'Dica da task nova',
    'wiki_link', 'https://oldschool.runescape.wiki/', 'image_link', 'https://example.com/x.png',
    'display_item_id', 1, 'verification', null, 'tags', null)
))::jsonb as r \gset

select t_assert('inserted = 1', :'r'::jsonb->>'inserted', '1');
select t_assert('new_tasks traz a task nova',
  (:'r'::jsonb->'new_tasks'->0->>'name') || ' / ' || (:'r'::jsonb->'new_tasks'->0->>'tier'),
  'Task nova de teste / easy');
select t_assert('...com o que o embed usa',
  (select string_agg(k, ',' order by k)
   from jsonb_object_keys(:'r'::jsonb->'new_tasks'->0) k),
  'id,image_link,name,tier,tip,wiki_link');
select t_assert('e so ela (as outras foram update)',
  jsonb_array_length(:'r'::jsonb->'new_tasks')::text, '1');
select t_assert('o grupo volta do medium para o easy',
  (:'r'::jsonb->>'tier_before') || '->' || (:'r'::jsonb->>'tier_after'), '2->1');

\echo '\n--- 3. rodar de novo nao avisa de novo ---'

select sync_tasks('segredo-de-teste', (select tasks from payload) || jsonb_build_array(
  jsonb_build_object(
    'id', '00000000-0000-0000-0000-00000000e457', 'tier', 'easy', 'tier_order', 1,
    'name', 'Task nova de teste', 'short_name', null, 'tip', 'Dica da task nova',
    'wiki_link', 'https://oldschool.runescape.wiki/', 'image_link', 'https://example.com/x.png',
    'display_item_id', 1, 'verification', null, 'tags', null)
))::jsonb as r \gset

select t_assert('inserted = 0 na segunda vez', :'r'::jsonb->>'inserted', '0');
select t_assert('new_tasks vazio na segunda vez', :'r'::jsonb->>'new_tasks', '[]');
select t_assert('removed_tasks vazio', :'r'::jsonb->>'removed_tasks', '[]');

\echo '\n--- 4. task que some do upstream ---'

-- O payload de agora inclui a task nova de teste: e a "lista do upstream".
update payload set tasks = tasks || jsonb_build_array(jsonb_build_object(
  'id', '00000000-0000-0000-0000-00000000e457', 'tier', 'easy', 'tier_order', 1,
  'name', 'Task nova de teste', 'short_name', null, 'tip', 'Dica da task nova',
  'wiki_link', 'https://oldschool.runescape.wiki/', 'image_link', 'https://example.com/x.png',
  'display_item_id', 1, 'verification', null, 'tags', null));

create or replace function t_try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return SQLERRM;
end $$;

insert into members (name, name_key) values ('Ana', 'ana'), ('Bruno', 'bruno'), ('Caio', 'caio');

-- Quatro tasks vao sumir:
--   livre  — medium que ninguem pegou
--   ativa  — medium ativa com a Ana, e de extra com o Bruno
--   feita  — easy que o Edu concluiu; o Caio esta com ela de extra
--   e457   — a easy de teste, a unica que segurava o tier easy aberto
-- E o Bruno, com outra medium ativa, pediu para trocar com a Ana.
create temp table fx as
select
  (select id from tasks where tier = 'medium' order by id limit 1 offset 0) as livre,
  (select id from tasks where tier = 'medium' order by id limit 1 offset 1) as ativa,
  (select id from tasks where tier = 'medium' order by id limit 1 offset 2) as do_bruno,
  (select task_id from assignments where status = 'completed' order by task_id limit 1) as feita,
  '00000000-0000-0000-0000-00000000e457'::uuid as e457,
  (select id from members where name = 'Ana')   as ana,
  (select id from members where name = 'Bruno') as bruno,
  (select id from members where name = 'Caio')  as caio;

insert into assignments (member_id, task_id) select ana, ativa from fx;
insert into assignments (member_id, task_id) select bruno, do_bruno from fx;
insert into extra_assignments (member_id, task_id) select bruno, ativa from fx;
insert into extra_assignments (member_id, task_id) select caio, feita from fx;
insert into swap_requests (from_member_id, to_member_id, from_assignment_id, to_assignment_id)
select bruno, ana,
       (select id from assignments where member_id = bruno and status = 'active'),
       (select id from assignments where member_id = ana and status = 'active')
from fx;

select pool_total() as pool_antes \gset

select sync_tasks('segredo-de-teste', (
  select jsonb_agg(x) from jsonb_array_elements((select tasks from payload)) x
  where (x->>'id')::uuid not in (select livre from fx union all select ativa from fx
                                 union all select feita from fx union all select e457 from fx)
))::jsonb as r \gset

select t_assert('4 tasks removidas', jsonb_array_length(:'r'::jsonb->'removed_tasks')::text, '4');
select t_assert('nada novo', :'r'::jsonb->>'new_tasks', '[]');

select t_assert('a ativa libera a Ana e a extra do Bruno',
  (select x->>'released' from jsonb_array_elements(:'r'::jsonb->'removed_tasks') x
   where (x->>'id')::uuid = (select ativa from fx)),
  '["Ana", "Bruno (extra)"]');

select t_assert('a feita sai como concluida, sem liberar ninguem',
  (select (x->>'completed') || ' ' || (x->>'released')
   from jsonb_array_elements(:'r'::jsonb->'removed_tasks') x
   where (x->>'id')::uuid = (select feita from fx)),
  'true []');

select t_assert('a livre: nao concluida, ninguem liberado',
  (select (x->>'completed') || ' ' || (x->>'released')
   from jsonb_array_elements(:'r'::jsonb->'removed_tasks') x
   where (x->>'id')::uuid = (select livre from fx)),
  'false []');

select t_assert('as 4 ganharam removed_at, nenhuma foi apagada',
  (select count(*) from tasks
   where removed_at is not null
     and id in (select livre from fx union all select ativa from fx
                union all select feita from fx union all select e457 from fx))::text,
  '4');

select t_assert('a Ana ficou sem task',
  (select count(*) from assignments a, fx where a.member_id = fx.ana and a.status = 'active')::text,
  '0');

select t_assert('a extra do Bruno saiu (seria extra de task livre)',
  (select count(*) from extra_assignments e, fx where e.member_id = fx.bruno)::text, '0');

select t_assert('a task principal do Bruno nao foi tocada',
  (select count(*) from assignments a, fx
   where a.member_id = fx.bruno and a.task_id = fx.do_bruno and a.status = 'active')::text,
  '1');

select t_assert('a extra do Caio na task feita continua',
  (select status from extra_assignments e, fx where e.member_id = fx.caio and e.task_id = fx.feita),
  'active');

select t_assert('o pedido de troca do Bruno com a Ana sumiu',
  (select count(*) from swap_requests)::text, '0');

select t_assert('a conclusao do Edu continua la',
  (select status from assignments a, fx where a.task_id = fx.feita), 'completed');

-- A feita continua no pool (numerador e denominador); as outras 3 saem.
select t_assert('pool_total cai 3', (:pool_antes - pool_total())::text, '3');

select t_assert('a easy de teste segurava o tier: easy -> medium',
  (:'r'::jsonb->>'tier_before') || '->' || (:'r'::jsonb->>'tier_after'), '1->2');

select t_assert('removida nao pode ser concluida pela lista -> TASK_NOT_FOUND',
  t_try(format('select complete_task_by_id(%L, %L)',
               (select token from members where name = 'Ana'), (select livre from fx))),
  'TASK_NOT_FOUND');

select t_assert('a removida nao aparece em /pending',
  (select count(*) from json_array_elements(
     list_pending((select token from members where name = 'Ana'), 200, 0, 'medium',
                  (select name from tasks where id = (select livre from fx)))->'items') x
   where (x->>'id')::uuid = (select livre from fx))::text,
  '0');

\echo '\n--- 5. rodar de novo nao avisa de novo ---'

select sync_tasks('segredo-de-teste', (
  select jsonb_agg(x) from jsonb_array_elements((select tasks from payload)) x
  where (x->>'id')::uuid not in (select livre from fx union all select ativa from fx
                                 union all select feita from fx union all select e457 from fx)
))::jsonb as r \gset

select t_assert('removed_tasks vazio na segunda vez', :'r'::jsonb->>'removed_tasks', '[]');

\echo '\n--- 6. task removida que volta ---'

select sync_tasks('segredo-de-teste', (
  select jsonb_agg(x) from jsonb_array_elements((select tasks from payload)) x
  where (x->>'id')::uuid not in (select ativa from fx union all select feita from fx
                                 union all select e457 from fx)
))::jsonb as r \gset

select t_assert('a livre volta como task nova',
  (select string_agg(x->>'id', ',') from jsonb_array_elements(:'r'::jsonb->'new_tasks') x),
  (select livre::text from fx));

select t_assert('...sem removed_at',
  (select coalesce(removed_at::text, 'null') from tasks where id = (select livre from fx)), 'null');

select t_assert('...e conta como update, nao insert', :'r'::jsonb->>'inserted', '0');

\echo '\n--- 7. remocao em massa e recusada ---'

select t_assert('26 sumindo de uma vez -> SYNC_TOO_MANY_REMOVED',
  split_part(t_try(format('select sync_tasks(%L, %L::jsonb)', 'segredo-de-teste', (
    select jsonb_agg(x) from (
      select x from jsonb_array_elements((select tasks from payload)) x
      where (x->>'id')::uuid not in (select ativa from fx union all select feita from fx
                                     union all select e457 from fx)
      order by x->>'id' offset 26
    ) s
  ))), ':', 1),
  'SYNC_TOO_MANY_REMOVED');

select t_assert('...e nao mexeu em nada',
  (select count(*) from tasks where removed_at is not null)::text, '3');

rollback;

\echo '\n=============================================='
\echo ' TODAS AS ASSERCOES PASSARAM'
\echo '=============================================='
