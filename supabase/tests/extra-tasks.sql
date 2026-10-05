-- =============================================================================
-- Suite das tasks EXTRA. Roda direto no Postgres, sem Supabase.
--
--   psql ... -f supabase/schema.sql
--   psql ... -f supabase/tests/extra-tasks.sql
--
-- Precisa da tabela `tasks` populada (basta o `npm run seed`, ou qualquer
-- conjunto com pelo menos 8 tasks do tier mais baixo). APAGA membros,
-- assignments e extras — nao roda contra o banco de uma run de verdade.
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

truncate extra_assignments, assignments, members cascade;
delete from group_state;
select set_group_code('TESTE1');

select join_group('TESTE1','Edu')   as j \gset
select join_group('TESTE1','Ana')   as j \gset
select join_group('TESTE1','Bruno') as j \gset

drop table if exists tk;
create temp table tk as select name, token from members;

-- Estado inicial: cada um conclui uma task, e sobra uma ativa para o Edu.
-- `edu_task` / `ana_task` / `bruno_task` ja SAIRAM do pool.
select roll_task(token) from tk where name = 'Edu';
select complete_task(token) from tk where name = 'Edu';
select roll_task(token) from tk where name = 'Ana';
select complete_task(token) from tk where name = 'Ana';
select roll_task(token) from tk where name = 'Bruno';
select complete_task(token) from tk where name = 'Bruno';
select roll_task(token) from tk where name = 'Edu';

drop table if exists fx;
create temp table fx as
select
  (select a.task_id from assignments a join members m on m.id = a.member_id
    where m.name = 'Edu' and a.status = 'completed')            as edu_task,
  (select a.task_id from assignments a join members m on m.id = a.member_id
    where m.name = 'Ana' and a.status = 'completed')            as ana_task,
  (select a.task_id from assignments a join members m on m.id = a.member_id
    where m.name = 'Bruno' and a.status = 'completed')          as bruno_task,
  (select a.task_id from assignments a join members m on m.id = a.member_id
    where m.name = 'Edu' and a.status = 'active')               as edu_active,
  (select t.id from tasks t
    where not exists (select 1 from assignments a where a.task_id = t.id)
    limit 1)                                                    as livre;

\echo '\n--- 1. quem pode pegar uma extra ---'

select t_assert('task inexistente -> TASK_NOT_FOUND',
  t_try($$select take_extra_task((select token from tk where name='Ana'),
                                 '00000000-0000-0000-0000-000000000000')$$),
  'TASK_NOT_FOUND');

select t_assert('task ainda no pool -> NOT_COMPLETED_YET',
  t_try($$select take_extra_task((select token from tk where name='Ana'),
                                 (select livre from fx))$$),
  'NOT_COMPLETED_YET');

-- A task ATIVA de OUTRA pessoa vale como extra: da para acompanhar alguem sem
-- esperar ela concluir. Devolve em seguida para nao gastar o slot de extra
-- ativa da Ana, que as secoes seguintes usam.
select t_assert('task ATIVA de outro -> aceita como extra',
  t_try($$select take_extra_task((select token from tk where name='Ana'),
                                 (select edu_active from fx))$$),
  'OK');
select t_assert('e devolve-la libera o slot de novo',
  t_try($$select abandon_extra_task((select token from tk where name='Ana'))$$),
  'OK');

select t_assert('quem tirou do pool nao repete -> EXTRA_ALREADY_DONE',
  t_try($$select take_extra_task((select token from tk where name='Edu'),
                                 (select edu_task from fx))$$),
  'EXTRA_ALREADY_DONE');

select t_assert('token invalido -> INVALID_TOKEN',
  t_try($$select take_extra_task('00000000-0000-0000-0000-000000000000',
                                 (select edu_task from fx))$$),
  'INVALID_TOKEN');

\echo '\n--- 2. pegar a extra ---'

select take_extra_task((select token from tk where name='Ana'),
                       (select edu_task from fx)) is not null as ok \gset
select t_assert('Ana pega a task do Edu como extra', :'ok', 't');

select t_assert('Ana tem 1 extra ativa',
  (select count(*)::text from extra_assignments
    where status = 'active'
      and member_id = (select id from members where name = 'Ana')),
  '1');

-- Regra 1: repetir a MESMA extra em pessoas diferentes e permitido.
select take_extra_task((select token from tk where name='Bruno'),
                       (select edu_task from fx)) is not null as ok \gset
select t_assert('Bruno pega a MESMA extra ao mesmo tempo (permitido)', :'ok', 't');

-- Regra 2: uma extra ativa por pessoa.
select t_assert('segunda extra simultanea -> EXTRA_ALREADY_ACTIVE',
  t_try($$select take_extra_task((select token from tk where name='Ana'),
                                 (select bruno_task from fx))$$),
  'EXTRA_ALREADY_ACTIVE');

-- E o indice unico e a garantia real, mesmo se a funcao tivesse um bug.
select t_assert('indice barra 2a extra ativa no insert cru',
  t_try($$insert into extra_assignments (member_id, task_id)
          values ((select id from members where name='Ana'),
                  (select bruno_task from fx))$$),
  'duplicate key value violates unique constraint "extra_assignments_one_active_per_member"');

\echo '\n--- 3. a extra nao mexe no pool ---'

select t_assert('completed_total do grupo inalterado',
  (get_state((select token from tk where name='Ana'))->>'completed_total'), '3');

select t_assert('assignments inalterados',
  (select count(*)::text from assignments), '4');

select t_assert('task extra NAO aparece na lista de pendentes',
  (select count(*)::text
   from json_array_elements(list_pending((select token from tk where name='Ana'))->'items') x
   where (x->>'id')::uuid = (select edu_task from fx)),
  '0');

\echo '\n--- 4. get_state mostra a extra ---'

select t_assert('extra da Ana aparece no get_state dela',
  (select x->'extra'->'task'->>'id'
   from json_array_elements(get_state((select token from tk where name='Ana'))->'members') x
   where x->>'name' = 'Ana'),
  (select edu_task::text from fx));

select t_assert('Edu (sem extra) tem extra = null',
  (select coalesce(x->'extra'->>'task', 'null')
   from json_array_elements(get_state((select token from tk where name='Edu'))->'members') x
   where x->>'name' = 'Edu'),
  'null');

select t_assert('a task NORMAL do Edu continua no lugar',
  (select x->'active'->'task'->>'id'
   from json_array_elements(get_state((select token from tk where name='Edu'))->'members') x
   where x->>'name' = 'Edu'),
  (select edu_active::text from fx));

\echo '\n--- 5. abandonar a extra ---'

select t_assert('abandonar sem extra -> NO_EXTRA_TASK',
  t_try($$select abandon_extra_task((select token from tk where name='Edu'))$$),
  'NO_EXTRA_TASK');

select abandon_extra_task((select token from tk where name='Bruno')) is not null as ok \gset
select t_assert('Bruno devolve a extra', :'ok', 't');

select t_assert('a linha some (nao vira "completed")',
  (select count(*)::text from extra_assignments
    where member_id = (select id from members where name = 'Bruno')),
  '0');

select take_extra_task((select token from tk where name='Bruno'),
                       (select edu_task from fx)) is not null as ok \gset
select t_assert('e pode pegar a mesma de novo depois de devolver', :'ok', 't');

\echo '\n--- 6. concluir a extra e o contador da /completed ---'

select t_assert('contador antes: so quem tirou do pool',
  (select x->>'completed_count'
   from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  '1');

select t_assert('concluir sem extra -> NO_EXTRA_TASK',
  t_try($$select complete_extra_task((select token from tk where name='Edu'))$$),
  'NO_EXTRA_TASK');

select complete_extra_task((select token from tk where name='Ana')) is not null as ok \gset
select t_assert('Ana conclui a extra', :'ok', 't');

select t_assert('contador subiu para 2',
  (select x->>'completed_count'
   from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  '2');

select t_assert('denominador = total de membros',
  (list_completed((select token from tk where name='Ana'))->>'member_total'), '3');

select t_assert('completions: nomes em ordem, com a flag de extra',
  (select string_agg(e.value->>'name' || '/' || (e.value->>'extra'), ' ' order by e.ord)
   from json_array_elements((
     select x->'completions'
     from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
     where (x->>'task_id')::uuid = (select edu_task from fx)
   )) with ordinality as e(value, ord)),
  'Edu/false Ana/true');

select t_assert('completions: toda conclusao tem data',
  (select count(*)::text
   from json_array_elements((
     select x->'completions'
     from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
     where (x->>'task_id')::uuid = (select edu_task from fx)
   )) e
   where e.value->>'completed_at' is not null),
  '2');

select t_assert('completions: a data da extra e a da conclusao DELA',
  (select (e.value->>'completed_at')::timestamptz
            > (select a.completed_at from assignments a
                where a.task_id = (select edu_task from fx))
   from json_array_elements((
     select x->'completions'
     from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
     where (x->>'task_id')::uuid = (select edu_task from fx)
   )) e
   where (e.value->>'extra')::boolean)::text,
  'true');

select t_assert('completions: uma task sem extra tem 1 entrada',
  (select json_array_length(x->'completions')::text
   from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
   where (x->>'task_id')::uuid = (select ana_task from fx)),
  '1');

select t_assert('a extra ativa do Bruno NAO conta ainda',
  (select x->>'completed_count'
   from json_array_elements(list_completed((select token from tk where name='Bruno'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  '2');

select complete_extra_task((select token from tk where name='Bruno')) is not null as ok \gset
select t_assert('contador chega a 3 (todo o grupo fez)',
  (select x->>'completed_count'
   from json_array_elements(list_completed((select token from tk where name='Bruno'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  '3');

select t_assert('o pool continua intocado: total do grupo ainda 3',
  (list_completed((select token from tk where name='Ana'))->>'total'), '3');

select t_assert('a lista continua com 1 linha por task (extra nao vira linha)',
  (select count(*)::text
   from json_array_elements(list_completed((select token from tk where name='Ana'))->'items')),
  '3');

\echo '\n--- 7. ninguem faz a mesma task duas vezes ---'

select t_assert('repetir extra ja concluida -> EXTRA_ALREADY_DONE',
  t_try($$select take_extra_task((select token from tk where name='Ana'),
                                 (select edu_task from fx))$$),
  'EXTRA_ALREADY_DONE');

select t_assert('indice barra a repeticao no insert cru',
  t_try($$insert into extra_assignments (member_id, task_id)
          values ((select id from members where name='Ana'),
                  (select edu_task from fx))$$),
  'duplicate key value violates unique constraint "extra_assignments_member_task_unique"');

\echo '\n--- 8. flags que a tela usa ---'

select t_assert('done_by_me: Edu tirou essa do pool',
  (select x->>'done_by_me'
   from json_array_elements(list_completed((select token from tk where name='Edu'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  'true');

select t_assert('done_by_me: Ana fez de extra',
  (select x->>'done_by_me'
   from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  'true');

select t_assert('done_by_me: Edu NAO fez a task da Ana',
  (select x->>'done_by_me'
   from json_array_elements(list_completed((select token from tk where name='Edu'))->'items') x
   where (x->>'task_id')::uuid = (select ana_task from fx)),
  'false');

select t_assert('has_active_extra falso com todas concluidas',
  (list_completed((select token from tk where name='Ana'))->>'has_active_extra'), 'false');

select take_extra_task((select token from tk where name='Edu'),
                       (select ana_task from fx)) is not null as ok \gset
select t_assert('has_active_extra verdadeiro depois de pegar',
  (list_completed((select token from tk where name='Edu'))->>'has_active_extra'), 'true');

select t_assert('extra_active marca a linha certa',
  (select x->>'extra_active'
   from json_array_elements(list_completed((select token from tk where name='Edu'))->'items') x
   where (x->>'task_id')::uuid = (select ana_task from fx)),
  'true');

select t_assert('...e so ela',
  (select x->>'extra_active'
   from json_array_elements(list_completed((select token from tk where name='Edu'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  'false');

\echo '\n--- 8b. filtros da /completed ---'

-- Estado aqui: edu_task feita por Edu (pool) + Ana e Bruno (extra) ·
-- ana_task so pela Ana (o Edu esta com ela de extra ATIVA, que nao conta) ·
-- bruno_task so pelo Bruno.

select t_assert('ja fiz (Edu): so a que ele tirou do pool',
  (select string_agg(x->>'task_id', ',')
   from json_array_elements(list_completed((select token from tk where name='Edu'),
                                           p_done_by_me => true)->'items') x),
  (select edu_task::text from fx));

select t_assert('nao fiz (Edu): extra ativa ainda nao conta como feita',
  (list_completed((select token from tk where name='Edu'),
                  p_done_by_me => false)->>'match_total'),
  '2');

select t_assert('ja fiz (Ana): pool + extra concluida',
  (list_completed((select token from tk where name='Ana'),
                  p_done_by_me => true)->>'match_total'),
  '2');

select t_assert('feitas pela Ana, vistas pelo Bruno',
  (select count(*)::text
   from json_array_elements(list_completed((select token from tk where name='Bruno'),
                                           p_done_by => (select id from members where name='Ana'))->'items') x
   where (x->>'task_id')::uuid in ((select edu_task from fx), (select ana_task from fx))),
  '2');

select t_assert('feitas pelo Bruno E que o Edu nao fez',
  (select string_agg(x->>'task_id', ',')
   from json_array_elements(list_completed((select token from tk where name='Edu'),
                                           p_done_by_me => false,
                                           p_done_by => (select id from members where name='Bruno'))->'items') x),
  (select bruno_task::text from fx));

select t_assert('busca ignora maiuscula e espaco em volta',
  (select bool_or((x->>'task_id')::uuid = (select ana_task from fx))::text
   from json_array_elements(list_completed(
     (select token from tk where name='Ana'),
     p_search => '  ' || upper((select name from tasks where id = (select ana_task from fx))) || ' '
   )->'items') x),
  'true');

select t_assert('busca sem resultado',
  (list_completed((select token from tk where name='Ana'), p_search => 'zzz-nao-existe')::jsonb
     -> 'items')::text,
  '[]');

select t_assert('busca vazia = sem filtro',
  (list_completed((select token from tk where name='Ana'), p_search => '   ')->>'match_total'),
  '3');

select t_assert('total continua o do pool inteiro com filtro',
  (list_completed((select token from tk where name='Edu'),
                  p_done_by_me => true)->>'total'),
  '3');

select t_assert('paginacao respeita o filtro',
  (select json_array_length(p->'items') || '/' || (p->>'match_total')
   from (select list_completed((select token from tk where name='Edu'), 1, 0,
                               p_done_by_me => false) as p) s),
  '1/2');

select t_assert('members: opcoes do filtro em ordem de entrada',
  (select string_agg(m->>'name', ' ' order by ord)
   from json_array_elements(list_completed((select token from tk where name='Ana'))->'members')
        with ordinality as e(m, ord)),
  'Edu Ana Bruno');

\echo '\n--- 9. saida do membro leva as extras junto ---'

select t_assert('delete do membro cascateia nas extras',
  t_try($$delete from members where name = 'Bruno'$$), 'OK');

select t_assert('extras do Bruno sumiram',
  (select count(*)::text from extra_assignments e
    left join members m on m.id = e.member_id where m.id is null), '0');

select t_assert('contador cai para 2 (Bruno saiu do grupo)',
  (select x->>'completed_count'
   from json_array_elements(list_completed((select token from tk where name='Ana'))->'items') x
   where (x->>'task_id')::uuid = (select edu_task from fx)),
  '2');

\echo '\n--- 10. roll_extra_task: extra sorteada ---'

-- Estado aqui: Edu e Ana (o Bruno saiu na secao 9, e a task dele voltou ao
-- pool). Recomeca as extras do zero. Para a Ana so ha uma candidata: edu_task
-- (a ana_task e dela, a task ativa do Edu nao esta concluida).
delete from extra_assignments;

select t_assert('sorteia a unica concluida que ela nao fez',
  (select roll_extra_task(token)->'task'->>'id' from tk where name = 'Ana'),
  (select edu_task::text from fx));

select t_assert('com extra ativa -> EXTRA_ALREADY_ACTIVE',
  t_try($$select roll_extra_task((select token from tk where name='Ana'))$$),
  'EXTRA_ALREADY_ACTIVE');

select complete_extra_task(token) from tk where name = 'Ana';

select t_assert('sem nada que ela nao tenha feito -> NO_EXTRA_AVAILABLE',
  t_try($$select roll_extra_task((select token from tk where name='Ana'))$$),
  'NO_EXTRA_AVAILABLE');

select t_assert('o Edu cai na task da Ana, nunca na propria',
  (select roll_extra_task(token)->'task'->>'id' from tk where name = 'Edu'),
  (select ana_task::text from fx));

select t_assert('token invalido -> INVALID_TOKEN',
  t_try($$select roll_extra_task('00000000-0000-0000-0000-000000000000')$$),
  'INVALID_TOKEN');

\echo '\n=============================================='
\echo ' TODAS AS ASSERCOES PASSARAM'
\echo '=============================================='
