\set ON_ERROR_STOP on
\pset pager off

-- helper: roda uma expressao e devolve o SQLERRM (codigo do erro) ou 'OK'
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
  raise notice 'ok   %  (%)', rpad(p_label, 52), p_got;
end $$;

truncate assignments, members cascade;
delete from group_state;
select set_group_code('TESTE1');

\echo '\n--- 1. login ---'
select t_assert('codigo errado -> INVALID_CODE',
  t_try($$select join_group('ERRADO','x')$$), 'INVALID_CODE');
select t_assert('nome vazio -> INVALID_NAME',
  t_try($$select join_group('TESTE1','   ')$$), 'INVALID_NAME');

select join_group('TESTE1','Edu')   as j \gset j_
select join_group('TESTE1','Ana')   as j \gset a_
select join_group('TESTE1','Bruno') as j \gset b_
select join_group('TESTE1','Caio')  as j \gset c_
select join_group('TESTE1','Dani')  as j \gset d_

select t_assert('5 membros cadastrados', (select count(*)::text from members), '5');
select t_assert('6o membro -> GROUP_FULL',
  t_try($$select join_group('TESTE1','Extra')$$), 'GROUP_FULL');
select t_assert('mesmo nome retoma o membro (nao cria novo)',
  (select count(*)::text from members), '5');
select t_assert('"edu" minusculo == "Edu"',
  ((select join_group('TESTE1','edu')->>'member_id') =
   (select id::text from members where name_key='edu'))::text, 'true');

-- guarda os tokens numa tabela auxiliar para o resto do teste
create temp table tk as
select name, token from members;

\echo '\n--- 2. gerar task e isolamento por usuario ---'
select roll_task((select token from tk where name='Edu')) is not null as ok \gset
select t_assert('so o Edu ficou com task ativa',
  (select count(*)::text from assignments where status='active'), '1');
select t_assert('a task ativa e do Edu',
  (select m.name from assignments a join members m on m.id=a.member_id where a.status='active'), 'Edu');
select t_assert('segundo roll do Edu -> ALREADY_ACTIVE',
  t_try($$select roll_task((select token from tk where name='Edu'))$$), 'ALREADY_ACTIVE');
select t_assert('token invalido -> INVALID_TOKEN',
  t_try($$select roll_task('00000000-0000-0000-0000-000000000000')$$), 'INVALID_TOKEN');

select roll_task(token) from tk where name <> 'Edu';
select t_assert('5 tasks ativas apos todos rolarem',
  (select count(*)::text from assignments where status='active'), '5');
select t_assert('as 5 tasks sao DIFERENTES',
  (select count(distinct task_id)::text from assignments where status='active'), '5');
select t_assert('as 5 sao todas EASY',
  (select count(distinct t.tier)::text || ':' || min(t.tier)
     from assignments a join tasks t on t.id=a.task_id where a.status='active'), '1:easy');
select t_assert('nenhum NOME de task repetido entre os ativos',
  (select count(distinct t.name)::text from assignments a join tasks t on t.id=a.task_id where a.status='active'), '5');

\echo '\n--- 3. concluir ---'
select t_assert('complete com token nulo -> INVALID_TOKEN',
  t_try($$select complete_task(null)$$), 'INVALID_TOKEN');
select complete_task((select token from tk where name='Edu')) is not null as ok \gset
select t_assert('Edu ficou sem ativa',
  (select count(*)::text from assignments a join members m on m.id=a.member_id where m.name='Edu' and a.status='active'), '0');
select t_assert('1 concluida no total',
  (select count(*)::text from assignments where status='completed'), '1');
select t_assert('concluir de novo -> NO_ACTIVE_TASK',
  t_try($$select complete_task((select token from tk where name='Edu'))$$), 'NO_ACTIVE_TASK');
select t_assert('list_completed mostra a do Edu',
  (select list_completed((select token from tk where name='Ana'))->'items'->0->>'member_name'), 'Edu');

\echo '\n--- 4. task concluida sai do pool para sempre ---'
select task_id as done_task from assignments where status='completed' \gset
select roll_task((select token from tk where name='Edu')) is not null as ok \gset
select t_assert('nova task do Edu != a que ele concluiu',
  (select (task_id <> :'done_task'::uuid)::text from assignments a join members m on m.id=a.member_id
    where m.name='Edu' and a.status='active'), 'true');
-- status='completed' para nao esbarrar no indice de "uma ativa por membro":
-- assim so o assignments_task_unique pode disparar.
select t_assert('task concluida nunca reaparece (indice unico)',
  t_try(format($$insert into assignments (member_id, task_id, status, completed_at) values
    ((select id from members where name='Ana'), %L, 'completed', now())$$, :'done_task')),
  'duplicate key value violates unique constraint "assignments_task_unique"');

\echo '\n--- 5. TIER_LOCKED: sobram easy, mas todas ativas ---'
-- conclui todas as easy MENOS 5 (as 5 que estao ativas agora)
insert into assignments (member_id, task_id, status, completed_at)
select (select id from members where name='Edu'), t.id, 'completed', now()
from tasks t
where t.tier='easy' and not exists (select 1 from assignments a where a.task_id=t.id);
select t_assert('easy restantes = as 5 ativas',
  (select count(*)::text from assignments a join tasks t on t.id=a.task_id where t.tier='easy' and a.status='active'), '5');

select complete_task((select token from tk where name='Ana')) is not null as ok \gset
select t_assert('Ana concluiu, agora tenta rolar -> TIER_LOCKED',
  t_try($$select roll_task((select token from tk where name='Ana'))$$), 'TIER_LOCKED');
select t_assert('e NAO recebeu medium',
  (select count(*)::text from assignments a join tasks t on t.id=a.task_id where t.tier='medium'), '0');

\echo '\n--- 6. tier avanca so quando TODAS as easy acabam ---'
select complete_task(token) from tk where name in ('Bruno','Caio','Dani');
select complete_task((select token from tk where name='Edu')) is not null as ok \gset
select t_assert('179 easy concluidas',
  (select count(*)::text from assignments a join tasks t on t.id=a.task_id where t.tier='easy' and a.status='completed'), '179');
select roll_task((select token from tk where name='Ana')) is not null as ok \gset
select t_assert('agora o roll cai em MEDIUM',
  (select t.tier from assignments a join tasks t on t.id=a.task_id join members m on m.id=a.member_id
    where m.name='Ana' and a.status='active'), 'medium');
select t_assert('current_tier do get_state = medium',
  (get_state((select token from tk where name='Ana'))->>'current_tier'), 'medium');

\echo '\n--- 7. integridade global ---'
select t_assert('nenhuma task atribuida 2x',
  (select coalesce(count(*),0)::text from (select task_id from assignments group by task_id having count(*)>1) x), '0');
select t_assert('nenhum membro com 2 ativas',
  (select coalesce(count(*),0)::text from (select member_id from assignments where status='active' group by member_id having count(*)>1) x), '0');

\echo '\n--- 8. undo_complete ---'
select complete_task((select token from tk where name='Ana')) is not null as ok \gset
select undo_complete((select token from tk where name='Ana')) is not null as ok \gset
select t_assert('undo devolveu a task para a Ana',
  (select count(*)::text from assignments a join members m on m.id=a.member_id where m.name='Ana' and a.status='active'), '1');
select t_assert('undo com task ativa -> ALREADY_ACTIVE',
  t_try($$select undo_complete((select token from tk where name='Ana'))$$), 'ALREADY_ACTIVE');
update assignments set completed_at = now() - interval '30 minutes'
  where status='completed' and member_id=(select id from members where name='Bruno');
select t_assert('undo depois de 10min -> UNDO_EXPIRED',
  t_try($$select undo_complete((select token from tk where name='Bruno'))$$), 'UNDO_EXPIRED');

\echo '\n=== TODOS OS TESTES PASSARAM ===\n'
