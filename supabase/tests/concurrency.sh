#!/usr/bin/env bash
# Teste de concorrencia REAL: N conexoes independentes chamando roll_task no
# mesmo instante, disputando um pool propositalmente pequeno.
set -uo pipefail
export PGPASSWORD=test
PSQL="psql -h localhost -p 55432 -U postgres -d tasklocked -qtAX"

N_MEMBERS=20
POOL=120         # 120 easy livres para 20 pessoas
ROUNDS=6

echo "=== $N_MEMBERS conexoes paralelas disputando $POOL tasks, $ROUNDS rodadas ==="

$PSQL >/dev/null <<SQL
truncate assignments, members cascade;
delete from group_state;
select set_group_code('CONC01');
update group_state set max_members = $((N_MEMBERS + 1));
insert into members (name, name_key) values ('bot','bot');
insert into assignments (member_id, task_id, status, completed_at)
select (select id from members where name_key='bot'), t.id, 'completed', now()
from tasks t where t.tier='easy' order by t.id offset $POOL;
SQL

for i in $(seq 1 $N_MEMBERS); do
  $PSQL -c "select join_group('CONC01','p$i')->>'token'" > /tmp/tok_$i.txt
done

# Invariante do gating: se existe QUALQUER assignment num tier K, entao todos os
# tiers < K precisam estar 100% concluidos agora. Retorna 0 quando esta tudo certo.
GATING_SQL="
select count(*) from (
  select distinct t.tier_order as k from assignments a join tasks t on t.id = a.task_id
) x
join lateral (
  select count(*) as tot,
         count(*) filter (where a2.status = 'completed') as done
  from tasks t2 left join assignments a2 on a2.task_id = t2.id
  where t2.tier_order < x.k
) y on true
where y.done <> y.tot;"

fail=0
for round in $(seq 1 $ROUNDS); do
  for i in $(seq 1 $N_MEMBERS); do
    ( tok=$(cat /tmp/tok_$i.txt)
      $PSQL -c "select coalesce((roll_task('$tok'))->>'id','ERR')" 2>/dev/null || echo EXC
    ) > /tmp/res_$i.txt 2>&1 &
  done
  wait

  got=$(cat /tmp/res_*.txt | grep -cE '^[0-9a-f]{8}-' || true)
  dup=$($PSQL -c "select count(*) from (select task_id from assignments group by task_id having count(*)>1) x")
  act=$($PSQL -c "select count(*) from assignments where status='active'")
  distinct_act=$($PSQL -c "select count(distinct task_id) from assignments where status='active'")
  two_active=$($PSQL -c "select count(*) from (select member_id from assignments where status='active' group by member_id having count(*)>1) x")
  dup_name=$($PSQL -c "select count(*) from (select t.name from assignments a join tasks t on t.id=a.task_id where a.status='active' group by t.name having count(*)>1) x")
  gating=$($PSQL -c "$GATING_SQL")
  tiers=$($PSQL -c "select string_agg(distinct t.tier,'/') from assignments a join tasks t on t.id=a.task_id where a.status='active'")

  printf "rodada %d: %2d rolls | ativas=%2s distintas=%2s (%s) | dup_task=%s dup_membro=%s nome_repetido=%s gating=%s\n" \
    "$round" "$got" "$act" "$distinct_act" "${tiers:-nenhuma}" "$dup" "$two_active" "$dup_name" "$gating"

  [ "$dup" = "0" ]              || { echo "  !! TASK ATRIBUIDA 2x"; fail=1; }
  [ "$act" = "$distinct_act" ]  || { echo "  !! DUAS PESSOAS COM A MESMA TASK ATIVA"; fail=1; }
  [ "$two_active" = "0" ]       || { echo "  !! MEMBRO COM 2 TASKS ATIVAS"; fail=1; }
  [ "$dup_name" = "0" ]         || { echo "  !! DOIS MEMBROS COM O MESMO NOME DE TASK"; fail=1; }
  [ "$gating" = "0" ]           || { echo "  !! TIER FUROU O GATING"; fail=1; }

  for i in $(seq 1 $N_MEMBERS); do
    tok=$(cat /tmp/tok_$i.txt)
    $PSQL -c "select complete_task('$tok')" >/dev/null 2>&1
  done
done

echo
echo "-- estado final --"
$PSQL -c "select t.tier, count(*) filter (where a.status='completed') as concluidas, count(*) as atribuidas
          from assignments a join tasks t on t.id=a.task_id group by t.tier order by min(t.tier_order);"
[ "$fail" = "0" ] && echo "=== CONCORRENCIA OK ===" || { echo "=== FALHOU ==="; exit 1; }
