/**
 * Zera o progresso do grupo para começar uma run nova.
 *
 *   npm run reset -- --yes
 *
 * Apaga: membros, assignments (tasks ativas e concluídas) e as tasks extra.
 * Mantém: a tabela `tasks` e o código do grupo — schema e seed continuam de pé.
 *
 * Para trocar o código depois: npm run set-code
 */
import { adminClient } from './_env.ts'

if (!process.argv.includes('--yes')) {
  console.error(`
  Isto apaga TODOS os membros e TODO o progresso do grupo
  (tasks ativas e a lista de concluídas). A tabela de tasks fica.

  Se for isso mesmo:  npm run reset -- --yes
`)
  process.exit(1)
}

const supabase = adminClient()

async function count(table: string): Promise<number> {
  const { count: n, error } = await supabase.from(table).select('*', { count: 'exact', head: true })
  if (error) {
    console.error(`\nfalhou ao ler ${table}: ${error.message}`)
    console.error('A SUPABASE_SERVICE_ROLE_KEY está correta no .env.local?\n')
    process.exit(1)
  }
  return n ?? 0
}

const before = {
  membros: await count('members'),
  assignments: await count('assignments'),
  extras: await count('extra_assignments'),
  tasks: await count('tasks'),
}

console.log(`
  antes:  ${before.membros} membros, ${before.assignments} assignments, ${before.extras} extras, ${before.tasks} tasks`)

// `not id is null` casa com todas as linhas — o PostgREST exige um filtro no delete.
// `extra_assignments` sairia junto pelo cascade de `members`, mas apagar antes
// deixa o relatorio abaixo honesto sobre o que foi removido.
for (const table of ['extra_assignments', 'assignments', 'members']) {
  const { error } = await supabase.from(table).delete().not('id', 'is', null)
  if (error) {
    console.error(`\nfalhou ao limpar ${table}: ${error.message}\n`)
    process.exit(1)
  }
}

const after = {
  membros: await count('members'),
  assignments: await count('assignments'),
  extras: await count('extra_assignments'),
  tasks: await count('tasks'),
}

console.log(`  depois: ${after.membros} membros, ${after.assignments} assignments, ${after.extras} extras, ${after.tasks} tasks`)

if (after.membros || after.assignments || after.extras) {
  console.error('\n  a limpeza não zerou tudo.\n')
  process.exit(1)
}
if (after.tasks !== before.tasks) {
  console.error('\n  as tasks foram afetadas — não deveriam ser.\n')
  process.exit(1)
}

console.log(`
  pronto. O código do grupo continua o mesmo e as ${after.tasks} tasks estão
  intactas — é só todo mundo entrar de novo.
`)
