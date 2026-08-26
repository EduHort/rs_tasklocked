/**
 * Carrega as tasks do task-list.json para a tabela `tasks`.
 *
 * Idempotente: usa upsert por id, entao rodar de novo nao duplica — e e assim
 * que se atualiza a lista quando o jogo ganha tasks novas. Quem ja existe tem
 * os campos atualizados no lugar, quem e novo entra. Nada em `assignments` ou
 * `extra_assignments` e tocado: o que o grupo ja concluiu continua concluido.
 *
 * Nao apaga: um id que sumir do JSON continua no banco (e no pool). Se isso
 * acontecer, o delete e manual — e antes dele o assignment daquela task, se
 * houver, por causa da FK.
 *
 *   npm run seed
 */
import { readFileSync } from 'node:fs'
import { adminClient } from './_env.ts'

const TIERS = ['easy', 'medium', 'hard', 'elite', 'master'] as const

type RawTask = {
  id: string
  name: string
  shortName?: string
  tip: string
  wikiLink: string
  imageLink: string
  displayItemId: number
  verification?: unknown
  tags?: string[]
}

const raw = JSON.parse(readFileSync('task-list.json', 'utf8')) as Record<string, RawTask[]>

const rows = TIERS.flatMap((tier, index) =>
  (raw[tier] ?? []).map((task) => ({
    id: task.id,
    tier,
    tier_order: index + 1,
    name: task.name,
    short_name: task.shortName ?? null,
    tip: task.tip,
    wiki_link: task.wikiLink,
    image_link: task.imageLink,
    display_item_id: task.displayItemId,
    verification: task.verification ?? null,
    tags: task.tags ?? null,
  })),
)

for (const tier of TIERS) {
  console.log(`  ${tier.padEnd(7)} ${(raw[tier] ?? []).length}`)
}
console.log(`  ${'total'.padEnd(7)} ${rows.length}\n`)

const ids = new Set(rows.map((r) => r.id))
if (ids.size !== rows.length) {
  console.error(`ids duplicados no JSON: ${rows.length - ids.size}`)
  process.exit(1)
}

const supabase = adminClient()
const BATCH = 500

for (let i = 0; i < rows.length; i += BATCH) {
  const batch = rows.slice(i, i + BATCH)
  const { error } = await supabase.from('tasks').upsert(batch, { onConflict: 'id' })
  if (error) {
    console.error('falhou:', error.message)
    process.exit(1)
  }
  console.log(`enviadas ${Math.min(i + BATCH, rows.length)}/${rows.length}`)
}

const { count, error } = await supabase.from('tasks').select('*', { count: 'exact', head: true })
if (error) {
  console.error(error.message)
  process.exit(1)
}
console.log(`\nok — ${count} tasks na tabela.`)
