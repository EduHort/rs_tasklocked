/**
 * Cron diario que mantem a lista de tasks em dia com o upstream.
 *
 * Busca o task-list.json do repo do Taskman, achata os cinco tiers no mesmo
 * formato que o `scripts/seed-tasks.ts` monta, e manda tudo para a RPC
 * `sync_tasks`. E o `npm run seed` sem ninguem no teclado.
 *
 * Nao carrega a service_role key de proposito: ela ignora a RLS, e um worker
 * comprometido leria a tabela `members` e viraria qualquer pessoa do grupo. O
 * `SYNC_SECRET` daqui so abre a `sync_tasks`, que so deixa `tasks` igual ao
 * upstream (e libera quem estava com uma task que saiu).
 *
 * Id que sumir do upstream sai do pool: a `sync_tasks` marca como removida e
 * libera quem estava com ela. O que o grupo ja concluiu fica no historico.
 *
 * Avisa num canal do Discord via webhook quando entra task nova, quando sai
 * task e quando a sync falha (opcional: sem `DISCORD_WEBHOOK_URL`, so
 * sincroniza).
 */

const UPSTREAM =
  'https://raw.githubusercontent.com/OSRS-Taskman/collection-log-master/main/src/main/resources/com/collectionlogmaster/task-list.json'

const TIERS = ['easy', 'medium', 'hard', 'elite', 'master'] as const
type Tier = (typeof TIERS)[number]

const TIER_LABEL: Record<Tier, string> = {
  easy: 'Easy',
  medium: 'Medium',
  hard: 'Hard',
  elite: 'Elite',
  master: 'Master',
}

type Env = {
  SUPABASE_URL: string
  SUPABASE_ANON_KEY: string
  SYNC_SECRET: string
  /** Webhook do canal. Sem ele, o worker so sincroniza e nao avisa ninguem. */
  DISCORD_WEBHOOK_URL?: string
}

/** Como a task vem do JSON do upstream (camelCase). */
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

/**
 * Tipado a mao em vez de puxar o @cloudflare/workers-types: sao dois campos, e
 * o projeto nao precisa de mais uma dependencia so para isso.
 */
type ScheduledController = { cron: string; scheduledTime: number }

/**
 * Uma task nova, como a `sync_tasks` devolve em `new_tasks`. Vem tambem dica,
 * wiki e imagem, mas o aviso so usa o nome.
 */
type NewTask = {
  id: string
  tier: Tier
  name: string
}

/** Uma task que sumiu do upstream, como a `sync_tasks` devolve em `removed_tasks`. */
type RemovedTask = {
  id: string
  tier: Tier
  name: string
  /** ja tinha sido concluida: so sai da lista, o historico fica */
  completed: boolean
  /** quem estava com ela e foi liberado ("Nome", ou "Nome (extra)") */
  released: string[]
}

type SyncResult = {
  inserted: number
  updated: number
  total: number
  // Opcionais: um schema.sql anterior a este worker nao manda. Sem eles, o
  // aviso so nao sai.
  new_tasks?: NewTask[]
  removed_tasks?: RemovedTask[]
  /** tier_order do tier atual antes/depois. null = o grupo tinha concluido tudo. */
  tier_before?: number | null
  tier_after?: number | null
}

/** O task-list.json do upstream, achatado na forma que a `sync_tasks` recebe. */
async function fetchUpstream() {
  const res = await fetch(UPSTREAM, {
    headers: { 'user-agent': 'rs-tasklocked-sync' },
  })
  if (!res.ok) {
    throw new Error(`upstream respondeu ${res.status} ${res.statusText}`)
  }

  const raw = (await res.json()) as Record<string, RawTask[]>

  const tasks = TIERS.flatMap((tier, index) =>
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

  // Um JSON valido mas com a estrutura trocada (outro layout, arquivo movido)
  // chegaria aqui como zero tasks. A `sync_tasks` recusaria pelo limite de
  // remocoes, mas o erro fica mais claro dito daqui.
  if (tasks.length === 0) {
    throw new Error('upstream veio sem nenhuma task — o formato do arquivo mudou?')
  }

  return tasks
}

async function sync(env: Env): Promise<SyncResult> {
  const tasks = await fetchUpstream()

  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/sync_tasks`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: env.SUPABASE_ANON_KEY,
      authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
    },
    body: JSON.stringify({ p_secret: env.SYNC_SECRET, p_tasks: tasks }),
  })

  const body = await response.text()
  if (!response.ok) {
    // O corpo traz o codigo cru da funcao (SYNC_TOO_MANY_REMOVED, INVALID_SYNC_SECRET…).
    throw new Error(`sync_tasks recusou (${response.status}): ${body}`)
  }

  return JSON.parse(body) as SyncResult
}

function truncate(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`
}

/** A mensagem do webhook: so texto, uma linha por task. */
function discordMessage(lines: string[]) {
  return {
    content: truncate(lines.join('\n'), MAX_CONTENT),
    // Os nomes vem do upstream, e o `content` e texto nosso — mas nada aqui
    // deve marcar ninguem, entao desliga as mencoes de vez.
    allowed_mentions: { parse: [] },
  }
}

/** Tasks listadas uma a uma por bloco; o que passar disso vira so a contagem. */
const MAX_LINES = 15

/** Limite do Discord para o `content`. */
const MAX_CONTENT = 2000

/** O cabecalho e uma linha por task, cortando em MAX_LINES. */
function block(header: string, items: string[]): string[] {
  const lines = [header, ...items.slice(0, MAX_LINES)]
  if (items.length > MAX_LINES) lines.push(`…e mais ${items.length - MAX_LINES}.`)
  return lines
}

/** "Ana", "Ana e Bruno", "Ana, Bruno e Caio". */
function joinNames(names: string[]): string {
  return names.length <= 1
    ? (names[0] ?? '')
    : `${names.slice(0, -1).join(', ')} e ${names[names.length - 1]}`
}

/** Uma linha por task removida: o que acontece com ela e com quem estava com ela. */
function removedLine(task: RemovedTask): string {
  const head = `• ${task.name}`
  if (task.released.length > 0) {
    const who = joinNames(task.released)
    return task.released.length === 1
      ? `${head} — estava com ${who}, que já pode pegar outra.`
      : `${head} — estava com ${who}, que já podem pegar outra.`
  }
  return task.completed ? `${head} — já concluída, continua no histórico.` : head
}

/**
 * O texto do aviso: o que entrou, o que saiu, e o alerta quando o tier atual
 * muda por causa disso.
 */
function summary(result: SyncResult, added: NewTask[], removed: RemovedTask[]): string[] {
  const lines: string[] = []

  if (added.length > 0) {
    lines.push(
      ...block(
        added.length === 1
          ? '**1 task entrou na lista:**'
          : `**${added.length} tasks entraram na lista:**`,
        added.map((task) => `• ${task.name}`),
      ),
    )
  }

  if (removed.length > 0) {
    // Linha em branco entre os blocos quando a mesma sync traz os dois.
    if (lines.length > 0) lines.push('')
    lines.push(
      ...block(
        removed.length === 1
          ? '**1 task saiu da lista:**'
          : `**${removed.length} tasks saíram da lista:**`,
        removed.map(removedLine),
      ),
    )
  }

  const before = result.tier_before ?? null
  const after = result.tier_after ?? null
  const label = (order: number) => TIER_LABEL[TIERS[order - 1]]
  const tierChanged = before !== after

  if (tierChanged) lines.push('')

  if (after !== null && (before === null || after < before)) {
    lines.push(
      before === null
        ? `⚠️ O grupo tinha zerado o pool — agora volta para o tier **${label(after)}**.`
        : `⚠️ Entrou task de um tier que o grupo já tinha fechado: o tier atual volta de **${label(before)}** para **${label(after)}**.`,
    )
  } else if (before !== null && (after === null || after > before)) {
    // So acontece por remocao: saiu a ultima task que segurava o tier.
    lines.push(
      after === null
        ? '🎉 Com isso o grupo zerou o pool.'
        : `Com isso o tier **${label(before)}** fechou: o tier atual agora é **${label(after)}**.`,
    )
  }

  return lines
}

async function postToDiscord(url: string, message: unknown): Promise<void> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(message),
  })
  if (!res.ok) {
    throw new Error(`discord respondeu ${res.status}: ${await res.text()}`)
  }
}

/**
 * Avisa no Discord o que a sync mudou no pool. Nunca lanca: quando isto roda,
 * as tasks ja estao no banco, e o cron nao deve aparecer como falho so porque
 * o aviso nao saiu. O preco e que um aviso perdido nao volta — no dia
 * seguinte a task ja nao e nova. O erro fica no log.
 *
 * Devolve o que aconteceu, para o log.
 */
async function notify(env: Env, result: SyncResult): Promise<string> {
  const removed = result.removed_tasks ?? []
  // Banco que estava vazio (primeira carga, depois de um reset): seriam as ~1000
  // tasks de uma vez. Isso nao e novidade, e so o pool nascendo.
  const added = result.total === result.inserted ? [] : (result.new_tasks ?? [])

  if (!env.DISCORD_WEBHOOK_URL) return 'sem webhook'
  if (added.length === 0 && removed.length === 0) return 'nada novo'

  try {
    await postToDiscord(env.DISCORD_WEBHOOK_URL, discordMessage(summary(result, added, removed)))
    return 'avisado'
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error(`aviso no discord falhou: ${message}`)
    return `falhou: ${message}`
  }
}

/** Sincroniza e avisa. Devolve o resumo que vai para o log. */
async function run(env: Env): Promise<string> {
  const result = await sync(env)
  const discord = await notify(env, result)
  // Sem o `new_tasks`: na primeira carga seriam ~1000 tasks no log.
  const { inserted, updated, total, tier_before, tier_after } = result
  const removed = result.removed_tasks?.length ?? 0
  return JSON.stringify({ inserted, updated, removed, total, tier_before, tier_after, discord })
}

/**
 * Avisa no Discord que a sync do cron falhou. Sem isto a falha so aparecia no
 * painel do Cloudflare, e a sync ficou parada desde 15/09/2026 sem ninguem saber.
 * Nunca lanca: o erro que importa e o da sync, que o `scheduled` relanca.
 */
async function notifyFailure(env: Env, error: string): Promise<void> {
  if (!env.DISCORD_WEBHOOK_URL) return
  try {
    await postToDiscord(env.DISCORD_WEBHOOK_URL, {
      content: [
        '⚠️ **A sincronização das tasks falhou** — o pool não foi atualizado com a lista do Taskman.',
        `\`\`\`\n${truncate(error, 1500)}\n\`\`\``,
        'Ela tenta de novo no próximo horário do cron.',
      ].join('\n'),
      allowed_mentions: { parse: [] },
    })
  } catch (err) {
    console.error(`aviso de falha no discord falhou: ${err instanceof Error ? err.message : err}`)
  }
}

/**
 * Manda um aviso de mentira, com duas tasks do upstream, para conferir o
 * webhook e a cara da mensagem sem esperar entrar task nova. Nao mexe no banco.
 */
async function testDiscord(env: Env): Promise<string> {
  if (!env.DISCORD_WEBHOOK_URL) {
    throw new Error('DISCORD_WEBHOOK_URL nao configurado — rode `npx wrangler secret put DISCORD_WEBHOOK_URL`')
  }

  const upstream = await fetchUpstream()
  const sample = (['easy', 'master'] as const)
    .map((tier) => upstream.find((task) => task.tier === tier))
    .filter((task) => task !== undefined)

  await postToDiscord(
    env.DISCORD_WEBHOOK_URL,
    discordMessage([
      '🧪 **Teste do aviso** — nada mudou no pool. Quando entrar task nova, fica assim:',
      '',
      `**${sample.length} tasks entraram na lista:**`,
      ...sample.map((task) => `• ${task.name}`),
    ]),
  )
  return 'aviso de teste enviado'
}

export default {
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    try {
      console.log(`[${controller.cron}] sync ok: ${await run(env)}`)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      console.error(`[${controller.cron}] sync falhou: ${message}`)
      await notifyFailure(env, message)
      // Relanca para a execucao aparecer como falha no painel do Cloudflare, em
      // vez de sumir como se tivesse dado certo.
      throw err
    }
  },

  /**
   * Disparo manual, para nao precisar esperar o cron so para saber se funciona:
   *
   *   curl -X POST https://<worker>.workers.dev -H "authorization: Bearer $SYNC_SECRET"
   *   curl -X POST https://<worker>.workers.dev/discord-teste -H "authorization: Bearer $SYNC_SECRET"
   *
   * O primeiro faz exatamente o que o cron faz (inclusive o aviso, se houver
   * task nova). O segundo so manda o aviso de teste no Discord.
   *
   * Protegido pelo mesmo segredo. Nao e uma defesa forte contra quem descobrir
   * a URL e tiver paciencia — mas o pior caso e um upsert da lista publica que
   * o cron ja faria sozinho todo dia, ou uma mensagem de teste no canal.
   */
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.headers.get('authorization') !== `Bearer ${env.SYNC_SECRET}`) {
      return new Response('nao autorizado\n', { status: 401 })
    }
    try {
      const test = new URL(request.url).pathname === '/discord-teste'
      return new Response(`${await (test ? testDiscord(env) : run(env))}\n`)
    } catch (err) {
      return new Response(`${err instanceof Error ? err.message : err}\n`, { status: 500 })
    }
  },
}
