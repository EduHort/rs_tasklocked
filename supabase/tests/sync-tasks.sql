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

rollback;

\echo '\n=============================================='
\echo ' TODAS AS ASSERCOES PASSARAM'
\echo '=============================================='
