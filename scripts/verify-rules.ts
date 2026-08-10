/**
 * Verifica as regras do jogo contra o banco de verdade, usando o MESMO cliente
 * supabase-js do front. Cobre: login, isolamento por usuario, unicidade das
 * tasks sob concorrencia, gating de tier e bloqueio da RLS.
 *
 *   npm run verify -- --yes-destructive
 *
 * ATENCAO: apaga membros e assignments. Rode antes da run comecar pra valer,
 * ou num projeto Supabase separado. As 990 tasks nao sao tocadas.
 */
import { adminClient, anonClient } from './_env.ts'
import type { GroupState, Task } from '../src/lib/types.ts'

if (!process.argv.includes('--yes-destructive')) {
  console.error(`
  Este script APAGA membros e assignments do banco.
  Se for isso mesmo:  npm run verify -- --yes-destructive
`)
  process.exit(1)
}

const admin = adminClient()
const anon = anonClient()
const CODE = 'VERIFY'
const NAMES = ['p1', 'p2', 'p3', 'p4', 'p5']

let failures = 0

function check(label: string, ok: boolean, detail = '') {
  console.log(`  ${ok ? 'ok  ' : 'FALHOU'}  ${label}${detail ? `  (${detail})` : ''}`)
  if (!ok) failures++
}

/** Roda uma RPC e devolve o codigo de erro, ou 'OK'. */
async function errorCode(fn: string, args: Record<string, unknown>): Promise<string> {
  const { error } = await anon.rpc(fn, args)
  return error ? error.message : 'OK'
}

async function reset() {
  const steps = [
    admin.from('assignments').delete().gt('assigned_at', '1970-01-01'),
    admin.from('members').delete().gt('created_at', '1970-01-01'),
    admin.rpc('set_group_code', { p_code: CODE }),
  ]
  for (const step of steps) {
    const { error } = await step
    if (error) {
      console.error(`\nreset falhou: ${error.message}`)
      console.error('A SUPABASE_SERVICE_ROLE_KEY esta correta no .env.local?\n')
      process.exit(1)
    }
  }
  const { count } = await admin.from('members').select('*', { count: 'exact', head: true })
  if (count !== 0) {
    console.error(`\nreset nao limpou os membros (${count} restantes).\n`)
    process.exit(1)
  }
}

async function join(name: string): Promise<string> {
  const { data, error } = await anon.rpc('join_group', { p_code: CODE, p_name: name })
  if (error) throw new Error(`join ${name}: ${error.message}`)
  return (data as { token: string }).token
}

async function state(token: string): Promise<GroupState> {
  const { data, error } = await anon.rpc('get_state', { p_token: token })
  if (error) throw new Error(error.message)
  return data as GroupState
}

async function activeRows() {
  const { data } = await admin
    .from('assignments')
    .select('member_id, task_id, task_name, status')
    .eq('status', 'active')
  return data ?? []
}

// ---------------------------------------------------------------------------

console.log('\n1. login')
await reset()
check('codigo errado -> INVALID_CODE', (await errorCode('join_group', { p_code: 'X', p_name: 'a' })) === 'INVALID_CODE')

const tokens = new Map<string, string>()
for (const name of NAMES) tokens.set(name, await join(name))
check('5 membros entraram', tokens.size === 5)
check('6o membro -> GROUP_FULL', (await errorCode('join_group', { p_code: CODE, p_name: 'p6' })) === 'GROUP_FULL')
check('mesmo nome retoma o token', (await join('p1')) === tokens.get('p1'))

console.log('\n2. gerar task e isolamento por usuario')
const t1 = tokens.get('p1')!
const { error: rollErr } = await anon.rpc('roll_task', { p_token: t1 })
check('p1 gerou sem erro', !rollErr, rollErr?.message)
check('SO p1 ficou com task ativa', (await activeRows()).length === 1)
check('2o roll de p1 -> ALREADY_ACTIVE', (await errorCode('roll_task', { p_token: t1 })) === 'ALREADY_ACTIVE')
check(
  'token invalido -> INVALID_TOKEN',
  (await errorCode('roll_task', { p_token: '00000000-0000-0000-0000-000000000000' })) === 'INVALID_TOKEN',
)

console.log('\n3. concorrencia: os 4 restantes clicam ao mesmo tempo')
const rolled = await Promise.all(
  NAMES.slice(1).map((n) => anon.rpc('roll_task', { p_token: tokens.get(n)! })),
)
const tasks = rolled.map((r) => r.data as Task | null).filter(Boolean) as Task[]
check('os 4 rolls deram certo', tasks.length === 4, rolled.find((r) => r.error)?.error?.message)

const active = await activeRows()
check('5 tasks ativas', active.length === 5)
check('todas com task_id DIFERENTE', new Set(active.map((a) => a.task_id)).size === 5)
check('todas com NOME diferente', new Set(active.map((a) => a.task_name)).size === 5)
check('cada membro com exatamente 1', new Set(active.map((a) => a.member_id)).size === 5)

const { data: allTasks } = await admin.from('tasks').select('id, tier')
const tierById = new Map((allTasks ?? []).map((t) => [t.id as string, t.tier as string]))
check('todas as 5 sao EASY', active.every((a) => tierById.get(a.task_id as string) === 'easy'))

console.log('\n4. concluir e lista compartilhada')
await anon.rpc('complete_task', { p_token: t1 })
check('p1 ficou sem ativa', (await activeRows()).length === 4)
check('concluir de novo -> NO_ACTIVE_TASK', (await errorCode('complete_task', { p_token: t1 })) === 'NO_ACTIVE_TASK')

const { data: page } = await anon.rpc('list_completed', { p_token: tokens.get('p2')!, p_limit: 10, p_offset: 0 })
const completed = page as { total: number; items: { member_name: string }[] }
check('p2 enxerga a task concluida por p1', completed.total === 1 && completed.items[0]?.member_name === 'p1')

console.log('\n5. gating de tier')
// conclui todas as easy que ainda nao foram atribuidas
const { data: freeEasy } = await admin.from('tasks').select('id').eq('tier', 'easy')
const { data: taken } = await admin.from('assignments').select('task_id')
const takenIds = new Set((taken ?? []).map((r) => r.task_id as string))
const p1Id = (await state(t1)).me
const toClose = (freeEasy ?? []).filter((t) => !takenIds.has(t.id as string))
for (let i = 0; i < toClose.length; i += 200) {
  await admin.from('assignments').insert(
    toClose.slice(i, i + 200).map((t) => ({
      member_id: p1Id,
      task_id: t.id,
      status: 'completed',
      completed_at: new Date().toISOString(),
    })),
  )
}
check('sobraram so as 4 easy ativas', (await activeRows()).length === 4)
check('p1 tenta rolar -> TIER_LOCKED', (await errorCode('roll_task', { p_token: t1 })) === 'TIER_LOCKED')

const { count: mediumCount } = await admin
  .from('assignments')
  .select('id, tasks!inner(tier)', { count: 'exact', head: true })
  .eq('tasks.tier', 'medium')
check('nenhuma medium vazou', (mediumCount ?? 0) === 0)

for (const n of NAMES.slice(1)) await anon.rpc('complete_task', { p_token: tokens.get(n)! })
const after = await state(t1)
check('as 179 easy foram concluidas', after.progress.find((p) => p.tier === 'easy')?.completed === 179)
check('current_tier virou medium', after.current_tier === 'medium')

const { data: nextTask } = await anon.rpc('roll_task', { p_token: t1 })
check('agora o roll cai em MEDIUM', (nextTask as Task | null)?.tier === 'medium')

console.log('\n6. integridade e seguranca')
const { data: everything } = await admin.from('assignments').select('task_id, member_id, status')
const ids = (everything ?? []).map((a) => a.task_id as string)
check('nenhuma task atribuida 2x', new Set(ids).size === ids.length)

for (const table of ['members', 'tasks', 'assignments', 'group_state']) {
  const { data, error } = await anon.from(table).select('*').limit(1)
  check(`anon nao le a tabela ${table}`, !!error || (data ?? []).length === 0, error?.message)
}
check(
  'anon nao pode trocar o codigo do grupo',
  (await errorCode('set_group_code', { p_code: 'HACK' })) !== 'OK',
)

console.log(`\n${failures === 0 ? 'TUDO OK' : `${failures} VERIFICACOES FALHARAM`}\n`)
await reset()
process.exit(failures === 0 ? 0 : 1)
