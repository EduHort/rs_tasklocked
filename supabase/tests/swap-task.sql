-- =============================================================================
-- Suite da troca de tasks ativas entre membros: request_swap, accept_swap,
-- decline_swap e cancel_swap. Roda direto no Postgres, sem Supabase.
--
--   psql ... -f supabase/schema.sql
--   psql ... -f supabase/tests/swap-task.sql
--
-- Precisa da tabela `tasks` populada (basta o `npm run seed`). APAGA membros,
-- assignments, extras e pedidos — nao roda contra o banco de uma run de verdade.
-- =============================================================================

\set ON_ERROR_STOP on
\pset pager off

create or replace function t_try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return SQLERRM;
end $$;

create or replace function t_assert(p_label text, p_got text, p_want text) returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'FALHOU: % | esperado=% obtido=%', p_label, p_want, p_got;
  end if;
  raise notice 'ok   %  (%)', rpad(p_label, 56), p_got;
end $$;

-- Task ativa, assignment ativo e token de alguem, pelo nome.
create or replace function t_task(p_name text) returns uuid language sql as $$
  select a.task_id from assignments a join members m on m.id = a.member_id
  where m.name = p_name and a.status = 'active'
$$;

create or replace function t_asg(p_name text) returns uuid language sql as $$
  select a.id from assignments a join members m on m.id = a.member_id
  where m.name = p_name and a.status = 'active'
$$;

create or replace function t_tok(p_name text) returns uuid language sql as $$
  select token from members where name = p_name
$$;

-- Pede a troca de `p_from` com `p_to` usando os assignments atuais dos dois.
create or replace function t_ask(p_from text, p_to text) returns text language sql as $$
  select t_try(format('select request_swap(%L, %L, %L)', t_tok(p_from), t_asg(p_from), t_asg(p_to)))
$$;

-- Id do pedido vivo de `p_from` para `p_to`, como o get_state de `p_to` mostra.
create or replace function t_req(p_from text, p_to text) returns uuid language sql as $$
  select (x->>'id')::uuid
  from json_array_elements(get_state(t_tok(p_to))->'swap_requests') x
  where (x->>'from_member_id')::uuid = (select id from members where name = p_from)
    and (x->>'to_member_id')::uuid   = (select id from members where name = p_to)
$$;

create or replace function t_pending(p_name text) returns text language sql as $$
  select json_array_length(get_state(t_tok(p_name))->'swap_requests')::text
$$;

truncate swap_requests, extra_assignments, assignments, members cascade;
delete from group_state;
select set_group_code('TESTE1');

select join_group('TESTE1','Edu')   as j \gset
select join_group('TESTE1','Ana')   as j \gset
select join_group('TESTE1','Bruno') as j \gset
select join_group('TESTE1','Caio')  as j \gset

select roll_task(t_tok(n)) from unnest(array['Edu','Ana','Caio']) n;

drop table if exists fx;
create temp table fx as
select t_task('Edu') as edu_task, t_task('Ana') as ana_task,
       t_asg('Edu')  as edu_asg,  t_asg('Ana')  as ana_asg;

\echo '\n--- 1. quem pode pedir ---'

select t_assert('sem task ativa -> NO_ACTIVE_TASK',
  t_try(format('select request_swap(%L, %L, %L)',
               t_tok('Bruno'), (select edu_asg from fx), (select ana_asg from fx))),
  'NO_ACTIVE_TASK');

select t_assert('com quem esta sem task -> SWAP_STALE',
  t_ask('Edu', 'Bruno'), 'SWAP_STALE');

select t_assert('consigo mesmo -> SWAP_STALE',
  t_ask('Edu', 'Edu'), 'SWAP_STALE');

select t_assert('assignment proprio desatualizado -> SWAP_STALE',
  t_try(format('select request_swap(%L, %L, %L)',
               t_tok('Edu'), (select ana_asg from fx), (select ana_asg from fx))),
  'SWAP_STALE');

select t_assert('token invalido -> INVALID_TOKEN',
  t_try(format('select request_swap(%L, %L, %L)',
               '00000000-0000-0000-0000-000000000000', (select edu_asg from fx), (select ana_asg from fx))),
  'INVALID_TOKEN');

\echo '\n--- 2. pedir nao troca nada ---'

select t_assert('pedido aceito', t_ask('Edu', 'Ana'), 'OK');

select t_assert('as tasks continuam as mesmas',
  (t_task('Edu') = (select edu_task from fx) and t_task('Ana') = (select ana_task from fx))::text,
  'true');

select t_assert('Ana ve o pedido recebido', t_pending('Ana'), '1');
select t_assert('Edu ve o pedido enviado', t_pending('Edu'), '1');
select t_assert('Caio nao ve pedido nenhum', t_pending('Caio'), '0');

select t_assert('segundo pedido do Edu -> SWAP_ALREADY_REQUESTED',
  t_ask('Edu', 'Caio'), 'SWAP_ALREADY_REQUESTED');

select t_assert('Ana pedindo de volta -> SWAP_INCOMING',
  t_ask('Ana', 'Edu'), 'SWAP_INCOMING');

select t_assert('Caio tambem pode pedir para a Ana', t_ask('Caio', 'Ana'), 'OK');
select t_assert('Ana ve os dois pedidos', t_pending('Ana'), '2');

\echo '\n--- 3. so quem recebeu responde ---'

select t_assert('quem pediu nao aceita o proprio -> SWAP_NOT_FOUND',
  t_try(format('select accept_swap(%L, %L)', t_tok('Edu'), t_req('Edu', 'Ana'))),
  'SWAP_NOT_FOUND');

select t_assert('terceiro nao recusa -> SWAP_NOT_FOUND',
  t_try(format('select decline_swap(%L, %L)', t_tok('Caio'), t_req('Edu', 'Ana'))),
  'SWAP_NOT_FOUND');

\echo '\n--- 4. recusar e cancelar ---'

select t_assert('Ana recusa o do Caio',
  t_try(format('select decline_swap(%L, %L)', t_tok('Ana'), t_req('Caio', 'Ana'))), 'OK');
select t_assert('sobrou so o do Edu', t_pending('Ana'), '1');
select t_assert('Caio sem pedido nenhum', t_pending('Caio'), '0');

select t_assert('Caio sem pedido para cancelar -> SWAP_NOT_FOUND',
  t_try(format('select cancel_swap(%L)', t_tok('Caio'))), 'SWAP_NOT_FOUND');

select t_assert('Edu cancela',
  t_try(format('select cancel_swap(%L)', t_tok('Edu'))), 'OK');
select t_assert('Ana nao ve mais nada', t_pending('Ana'), '0');
select t_assert('Edu pode pedir de novo', t_ask('Edu', 'Ana'), 'OK');

\echo '\n--- 5. aceitar ---'

-- Recua o relogio para ver o assigned_at recomecar. Caio pede a Ana tambem:
-- quando ela aceitar o Edu, o pedido do Caio aponta para uma task que ela nao
-- tem mais e precisa sumir.
update assignments set assigned_at = now() - interval '2 days' where status = 'active';
select t_ask('Caio', 'Ana');

select t_assert('Ana aceita e recebe a task do Edu',
  (select accept_swap(t_tok('Ana'), t_req('Edu', 'Ana'))->>'id'),
  (select edu_task::text from fx));

select t_assert('Edu ficou com a task da Ana',
  t_task('Edu')::text, (select ana_task::text from fx));

select t_assert('relogio recomecou para os dois',
  (select count(*) from assignments
   where status = 'active' and assigned_at > now() - interval '1 minute')::text,
  '2');

select t_assert('continuam 3 assignments, todos ativos',
  (select count(*) || '/' || count(*) filter (where status = 'active') from assignments),
  '3/3');

select t_assert('o pedido aceito sumiu da tabela',
  (select count(*) from swap_requests where from_member_id = (select id from members where name='Edu'))::text,
  '0');

select t_assert('o pedido do Caio morreu junto',
  (select count(*) from swap_requests)::text, '0');

select t_assert('aceitar de novo -> SWAP_NOT_FOUND',
  t_try(format('select accept_swap(%L, %L)', t_tok('Ana'), (select gen_random_uuid()))),
  'SWAP_NOT_FOUND');

\echo '\n--- 6. o pedido morre quando alguem conclui ---'

select t_ask('Edu', 'Ana');
drop table if exists rq;
create temp table rq as select t_req('Edu', 'Ana') as id;

select complete_task(t_tok('Edu'));

select t_assert('Ana nao ve mais o pedido', t_pending('Ana'), '0');

select t_assert('aceitar o pedido morto -> SWAP_STALE',
  t_try(format('select accept_swap(%L, %L)', t_tok('Ana'), (select id from rq))),
  'SWAP_STALE');

select t_assert('a conclusao do Edu continua la',
  (select status from assignments where task_id = (select ana_task from fx)),
  'completed');

-- O pedido morto ainda ocupa o indice da regra 3: o request_swap faz a faxina.
select roll_task(t_tok('Edu'));
select t_assert('Edu pede de novo apesar do pedido morto', t_ask('Edu', 'Ana'), 'OK');
select cancel_swap(t_tok('Edu'));

\echo '\n--- 7. extras (regra 4) ---'

-- Bruno pega de extra a task ativa do Edu: nao pode recebe-la.
select roll_task(t_tok('Bruno'));
select take_extra_task(t_tok('Bruno'), t_task('Edu'));

select t_assert('pedir a propria extra ativa -> SWAP_EXTRA_CONFLICT',
  t_ask('Bruno', 'Edu'), 'SWAP_EXTRA_CONFLICT');

select t_assert('vale tambem quando quem pede e o outro',
  t_ask('Edu', 'Bruno'), 'SWAP_EXTRA_CONFLICT');

-- Pedido feito antes da extra: o accept checa de novo.
select t_assert('Caio pede para o Edu', t_ask('Caio', 'Edu'), 'OK');
select take_extra_task(t_tok('Caio'), t_task('Edu'));
select complete_extra_task(t_tok('Bruno'));

select t_assert('extra pega depois do pedido -> SWAP_EXTRA_CONFLICT',
  t_try(format('select accept_swap(%L, %L)', t_tok('Edu'), t_req('Caio', 'Edu'))),
  'SWAP_EXTRA_CONFLICT');

select t_assert('extra ja concluida tambem bloqueia',
  t_ask('Bruno', 'Edu'), 'SWAP_EXTRA_CONFLICT');

\echo '\n=============================================='
\echo ' TODAS AS ASSERCOES PASSARAM'
\echo '=============================================='
