-- =============================================================================
-- Suite da get_stats (tela /stats). Roda direto no Postgres, sem Supabase.
--
--   psql ... -f supabase/schema.sql
--   psql ... -f supabase/tests/stats.sql
--
-- Precisa da tabela `tasks` populada (basta o `npm run seed`, ou qualquer
-- conjunto com pelo menos 6 tasks). APAGA membros, assignments e extras — nao
-- roda contra o banco de uma run de verdade.
--
-- As linhas entram por insert cru, com datas fixas: e o unico jeito de saber
-- de antemao quanto tempo cada task levou.
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
select join_group('TESTE1','Dani')  as j \gset

drop table if exists tk;
create temp table tk as select id, name, token from members;

\echo '\n--- 0. grupo sem nada feito ---'

drop table if exists s;
create temp table s as select get_stats(token)::jsonb as j from tk where name = 'Edu';

select t_assert('sem conclusoes: started_at nulo', (select j->>'started_at' from s), null);
select t_assert('sem conclusoes: weeks vazio',     (select j->>'weeks' from s), '[]');
select t_assert('sem conclusoes: slowest vazio',   (select j->>'slowest' from s), '[]');
select t_assert('sem conclusoes: current_streak 0', (select j->>'current_streak' from s), '0');
select t_assert('sem conclusoes: membros com total 0',
  (select count(*)::text from jsonb_array_elements((select j->'members' from s)) m
    where (m->>'total')::int = 0), '4');

-- Seis tasks quaisquer, numeradas.
drop table if exists tt;
create temp table tt as
select row_number() over (order by id) as n, id from (select id from tasks order by id limit 6) x;

-- Cenario (horarios de Brasilia):
--   Edu   t1  01/09 10:00 -> 03/09 10:00   2 dias        (172800 s)
--   Edu   t2  03/09 12:00 -> 03/09 13:00   1 h           (3600 s)
--   Ana   t3  registrada direto em 04/09 20:00 — fica fora dos tempos
--   Ana   t4  ativa
--   Bruno t5  08/09 09:00 -> 08/09 09:10   10 min        (600 s)
--   Bruno t6  ha 3 h      -> ha 1 h        2 h           (7200 s) — mantem a sequencia atual viva
--   Ana   t1 de extra 03/09 22:00 -> 03/09 23:30  1h30  (5400 s)
--     -> ja e 04/09 em UTC: so conta no dia 03 se o fuso estiver certo.
--   Dani  nada
insert into assignments (member_id, task_id, status, assigned_at, completed_at)
select m.id, t.id, 'completed', x.a::timestamptz, x.c::timestamptz
from (values
  ('Edu',   1, '2026-09-01 10:00-03', '2026-09-03 10:00-03'),
  ('Edu',   2, '2026-09-03 12:00-03', '2026-09-03 13:00-03'),
  ('Ana',   3, '2026-09-04 20:00-03', '2026-09-04 20:00-03'),
  ('Bruno', 5, '2026-09-08 09:00-03', '2026-09-08 09:10-03')
) as x(who, n, a, c)
join members m on m.name = x.who
join tt t on t.n = x.n;

insert into assignments (member_id, task_id, status, assigned_at, completed_at)
select m.id, t.id, 'completed', now() - interval '3 hours', now() - interval '1 hour'
from members m, tt t where m.name = 'Bruno' and t.n = 6;

insert into assignments (member_id, task_id, assigned_at)
select m.id, t.id, '2026-09-05 10:00-03'
from members m, tt t where m.name = 'Ana' and t.n = 4;

insert into extra_assignments (member_id, task_id, status, assigned_at, completed_at)
select m.id, t.id, 'completed', '2026-09-03 22:00-03', '2026-09-03 23:30-03'
from members m, tt t where m.name = 'Ana' and t.n = 1;

drop table if exists s;
create temp table s as select get_stats(token)::jsonb as j from tk where name = 'Edu';

\echo '\n--- 1. totais ---'
select t_assert('me = quem pediu',
  (select j->>'me' from s), (select id::text from tk where name = 'Edu'));
select t_assert('started_at = primeira task pega',
  (select (j->>'started_at')::timestamptz = '2026-09-01 10:00-03' from s)::text, 'true');
select t_assert('pool_completed (registrada conta)', (select j->>'pool_completed' from s), '5');
select t_assert('extra_completed',                   (select j->>'extra_completed' from s), '1');
select t_assert('task_total = tabela tasks',
  (select j->>'task_total' from s), (select count(*)::text from tasks));
select t_assert('mediana geral ignora a registrada',  (select j->>'median_secs' from s), '5400');

\echo '\n--- 2. dias e sequencias (fuso de Brasilia) ---'
select t_assert('dias com conclusao', (select j->>'active_days' from s), '4');
select t_assert('melhor dia = 03/09 (extra das 23:30 conta no dia 03)',
  (select j->'best_day'->>'day' from s), '2026-09-03');
select t_assert('melhor dia teve 3', (select j->'best_day'->>'count' from s), '3');
select t_assert('maior sequencia = 2 dias',  (select j->'longest_streak'->>'days' from s), '2');
select t_assert('maior sequencia comeca 03/09', (select j->'longest_streak'->>'first_day' from s), '2026-09-03');
select t_assert('sequencia atual = 1 (a de hoje)', (select j->>'current_streak' from s), '1');

\echo '\n--- 3. ranking por pessoa ---'
select t_assert('ordem: total, depois pool, depois nome',
  (select string_agg(m->>'name', ',' order by o)
     from jsonb_array_elements((select j->'members' from s)) with ordinality as x(m, o)),
  'Bruno,Edu,Ana,Dani');
select t_assert('Ana: 1 pool + 1 extra',
  (select m->>'pool' || '+' || (m->>'extra') from jsonb_array_elements((select j->'members' from s)) m
    where m->>'name' = 'Ana'), '1+1');
select t_assert('Ana: mediana so da extra (registrada fora)',
  (select m->>'median_secs' from jsonb_array_elements((select j->'members' from s)) m
    where m->>'name' = 'Ana'), '5400');
select t_assert('Edu: mediana de 2 d e 1 h',
  (select m->>'median_secs' from jsonb_array_elements((select j->'members' from s)) m
    where m->>'name' = 'Edu'), '88200');
select t_assert('Dani aparece zerada, mediana nula',
  (select (m->>'total') || '/' || coalesce(m->>'median_secs', 'null')
     from jsonb_array_elements((select j->'members' from s)) m where m->>'name' = 'Dani'), '0/null');

\echo '\n--- 4. mais demoradas / mais rapidas ---'
select t_assert('slowest tem so as cronometradas', (select jsonb_array_length(j->'slowest') from s)::text, '5');
select t_assert('mais demorada = t1 do Edu',
  (select j->'slowest'->0->>'member_name' || ' ' || (j->'slowest'->0->>'secs') from s), 'Edu 172800');
select t_assert('a extra da Ana entra marcada',
  (select count(*)::text from jsonb_array_elements((select j->'slowest' from s)) x
    where (x->>'extra')::boolean and x->>'member_name' = 'Ana'), '1');
select t_assert('registrada direto nunca aparece',
  (select count(*)::text from jsonb_array_elements((select j->'slowest' from s)) x
    where x->>'task_id' = (select id::text from tt where n = 3)), '0');
select t_assert('mais rapida = 10 min do Bruno',
  (select j->'fastest'->0->>'secs' from s), '600');
select t_assert('ativa nao entra em lugar nenhum',
  (select count(*)::text from jsonb_array_elements((select j->'slowest' from s)) x
    where x->>'task_id' = (select id::text from tt where n = 4)), '0');

\echo '\n--- 5. semanas ---'
select t_assert('primeira semana = segunda 31/08', (select j->'weeks'->0->>'week' from s), '2026-08-31');
select t_assert('semana 31/08: 3 do pool + 1 extra',
  (select (j->'weeks'->0->>'pool') || '+' || (j->'weeks'->0->>'extra') from s), '3+1');
select t_assert('semana 07/09: 1 do pool',
  (select (j->'weeks'->1->>'pool') from s), '1');
select t_assert('semana vazia aparece zerada',
  (select (j->'weeks'->2->>'week') || ' ' || (j->'weeks'->2->>'pool') from s), '2026-09-14 0');
select t_assert('ultima semana = a atual',
  (select (j->'weeks'->-1->>'week')::date
          = date_trunc('week', now() at time zone 'America/Sao_Paulo')::date from s)::text, 'true');
select t_assert('soma das semanas = todas as conclusoes',
  (select sum((w->>'pool')::int + (w->>'extra')::int)::text
     from jsonb_array_elements((select j->'weeks' from s)) w), '6');

\echo '\n--- 6. acesso ---'
select t_assert('token invalido -> INVALID_TOKEN',
  t_try($$select get_stats('00000000-0000-0000-0000-000000000000')$$), 'INVALID_TOKEN');
select t_assert('nao mexe em nada: assignments iguais',
  (select count(*)::text from assignments), '6');

\echo '\n=============================================='
\echo ' TODAS AS ASSERCOES PASSARAM'
\echo '=============================================='
