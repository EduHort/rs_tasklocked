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

\echo '\n--- 2b. duas pessoas PODEM ficar com tasks de MESMO nome ---'
-- O dataset tem 161 pares (tier, nome) repetidos. Sao ids diferentes, e nada
-- mais bloqueia isso: o unico indice de duplicidade e o de task_id.
select t.name as dup_name from tasks t
  where t.tier='easy'
    and not exists (select 1 from assignments a where a.task_id = t.id)
  group by t.name having count(*) >= 2
  order by t.name limit 1 \gset
delete from assignments a using members m
  where m.id = a.member_id and m.name in ('Edu','Ana') and a.status='active';
select t_assert('atribuir dois ids do MESMO nome -> aceito',
  t_try(format($$insert into assignments (member_id, task_id, status)
    select (select id from members where name = case x.rn when 1 then 'Edu' else 'Ana' end),
           x.id, 'active'
    from (select id, row_number() over (order by id) as rn
            from tasks where tier='easy' and name=%L order by id limit 2) x$$, :'dup_name')), 'OK');
select t_assert('Edu e Ana estao com o mesmo texto na tela',
  (select count(distinct t.name)::text from assignments a
     join tasks t on t.id=a.task_id join members m on m.id=a.member_id
   where a.status='active' and m.name in ('Edu','Ana')), '1');
select t_assert('e o grupo segue com 5 ativas',
  (select count(*)::text from assignments where status='active'), '5');
select t_assert('mesmo assim, o MESMO id duas vezes -> recusado',
  t_try($$insert into assignments (member_id, task_id, status)
    select (select id from members where name='Bruno'), task_id, 'completed'
    from assignments where status='active' limit 1$$),
  'duplicate key value violates unique constraint "assignments_task_unique"');

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

\echo '\n--- 9. list_pending e complete_task_by_id ---'
-- Neste ponto: easy 100% concluida e a Ana com uma medium ativa (secao 8).
-- O tamanho do pool sai da propria tabela: o task-list.json muda de tamanho
-- entre as atualizacoes da lista do jogo, e o teste nao pode ter numero fixo.
select t_assert('total de pendentes = tasks - concluidas',
  (((list_pending((select token from tk where name='Ana'))->>'total')::int =
    (select count(*) from tasks) -
    (select count(*) from assignments where status='completed'))::text), 'true');
select t_assert('nenhuma easy sobrou nos pendentes',
  (select count(*)::text from json_array_elements(
     list_pending((select token from tk where name='Ana'), 200)->'items') e
   where e->>'tier' = 'easy'), '0');
select t_assert('filtro por tier so traz hard',
  (select count(distinct e->>'tier')::text || ':' || min(e->>'tier') from json_array_elements(
     list_pending((select token from tk where name='Edu'), 50, 0, 'hard')->'items') e), '1:hard');
select t_assert('busca por texto: nenhum resultado fora do termo',
  (select count(*) filter (where e->>'name' !~* 'wintertodt')::text from json_array_elements(
     list_pending((select token from tk where name='Edu'), 50, 0, null, 'wintertodt')->'items') e), '0');
select t_assert('busca por texto: e traz pelo menos um',
  ((select count(*) from json_array_elements(
     list_pending((select token from tk where name='Edu'), 50, 0, null, 'wintertodt')->'items') e) > 0)::text, 'true');

-- concluir direto uma task que ninguem sorteou
select id as free_task from tasks t where t.tier='hard'
  and not exists (select 1 from assignments a where a.task_id = t.id)
  order by id limit 1 \gset
select t_assert('concluir direto uma task livre -> OK',
  t_try(format($$select complete_task_by_id((select token from tk where name='Ana'), %L)$$, :'free_task')), 'OK');
select t_assert('ela entrou como concluida em nome da Ana',
  (select m.name from assignments a join members m on m.id=a.member_id
    where a.task_id = :'free_task'::uuid and a.status='completed'), 'Ana');
select t_assert('e sumiu da lista de pendentes',
  (select count(*)::text from json_array_elements(
     list_pending((select token from tk where name='Ana'), 200, 0, 'hard')->'items') e
   where e->>'id' = :'free_task'), '0');
select t_assert('concluir a mesma de novo -> ALREADY_COMPLETED',
  t_try(format($$select complete_task_by_id((select token from tk where name='Ana'), %L)$$, :'free_task')),
  'ALREADY_COMPLETED');
select t_assert('id que nao existe -> TASK_NOT_FOUND',
  t_try($$select complete_task_by_id((select token from tk where name='Ana'),
    '00000000-0000-0000-0000-000000000000')$$), 'TASK_NOT_FOUND');

-- a task ativa de outra pessoa continua fora do alcance
select a.task_id as ana_task from assignments a join members m on m.id=a.member_id
  where m.name='Ana' and a.status='active' \gset
select t_assert('concluir a ativa de outro membro -> TASK_TAKEN',
  t_try(format($$select complete_task_by_id((select token from tk where name='Edu'), %L)$$, :'ana_task')),
  'TASK_TAKEN');
select t_assert('a Ana conclui a propria ativa -> OK',
  t_try(format($$select complete_task_by_id((select token from tk where name='Ana'), %L)$$, :'ana_task')), 'OK');
select t_assert('e ela ficou sem task ativa',
  (select count(*)::text from assignments a join members m on m.id=a.member_id
    where m.name='Ana' and a.status='active'), '0');

\echo '\n=== TODOS OS TESTES PASSARAM ===\n'
