/**
 * Cron diario que mantem a lista de tasks em dia com o upstream.
 *
 * Busca o task-list.json do repo do Taskman, achata os cinco tiers no mesmo
 * formato que o `scripts/seed-tasks.ts` monta, e manda tudo para a RPC
 * `sync_tasks`. E o `npm run seed` sem ninguem no teclado.
 *
 * Nao carrega a service_role key de proposito: ela ignora a RLS, e um worker
 * comprometido leria a tabela `members` e viraria qualquer pessoa do grupo. O
 * `SYNC_SECRET` daqui so abre a `sync_tasks`, que so faz upsert em `tasks`.
 *
 * Nao apaga nada. Id que sumir do upstream continua no pool — tirar uma task do
 * ar e decisao humana, nao de cron.
 *
 * Quando entra task nova, avisa num canal do Discord via webhook (opcional: sem
 * `DISCORD_WEBHOOK_URL`, so sincroniza).
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

/** Barra lateral do embed — as mesmas `--color-tier-*` do site. */
const TIER_COLOR: Record<Tier, number> = {
  easy: 0x6f9c4a,
  medium: 0x4a86b8,
  hard: 0x9a6bbf,
  elite: 0xd08a3a,
  master: 0xc0503f,
}

/** Limite do Discord por mensagem. O que passar disso vira so a contagem. */
const MAX_EMBEDS = 10

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

/** Uma task nova, como a `sync_tasks` devolve em `new_tasks`. */
type NewTask = {
  id: string
  tier: Tier
  name: string
  tip: string
  wiki_link: string
  image_link: string
}

type SyncResult = {
  inserted: number
  updated: number
  total: number
  // Opcionais: um schema.sql anterior a este worker nao manda. Sem eles, o
  // aviso so nao sai.
  new_tasks?: NewTask[]
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
  // chegaria aqui como zero tasks. A `sync_tasks` recusaria pelo guard de
  // encolhimento, mas o erro fica mais claro dito daqui.
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
    // O corpo traz o codigo cru da funcao (SYNC_SHRANK, INVALID_SYNC_SECRET…).
    throw new Error(`sync_tasks recusou (${response.status}): ${body}`)
  }

  return JSON.parse(body) as SyncResult
}

function truncate(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`
}

/**
 * A mensagem do webhook: uma linha de resumo e um embed por task — nome com
 * link da wiki, a dica, a imagem e a cor do tier.
 */
function discordMessage(lines: string[], tasks: NewTask[]) {
  const content =
    tasks.length > MAX_EMBEDS
      ? [...lines, `Aqui vão as ${MAX_EMBEDS} primeiras — o resto está em "A fazer" no site.`]
      : lines

  return {
    content: content.join('\n'),
    // Os nomes vem do upstream, e o `content` e texto nosso — mas nada aqui
    // deve marcar ninguem, entao desliga as mencoes de vez.
    allowed_mentions: { parse: [] },
    embeds: tasks.slice(0, MAX_EMBEDS).map((task) => ({
      title: truncate(task.name, 256),
      url: task.wiki_link,
      description: truncate(task.tip, 300),
      color: TIER_COLOR[task.tier],
      thumbnail: { url: task.image_link },
      footer: { text: TIER_LABEL[task.tier] },
    })),
  }
}

/** A linha de resumo do aviso, com o alerta quando o tier atual volta para tras. */
function summary(result: SyncResult, tasks: NewTask[]): string[] {
  const lines = [
    tasks.length === 1
      ? '**1 task nova** entrou no pool.'
      : `**${tasks.length} tasks novas** entraram no pool.`,
  ]

  const before = result.tier_before ?? null
  const after = result.tier_after ?? null
  if (after !== null && (before === null || after < before)) {
    const tier = TIER_LABEL[TIERS[after - 1]]
    lines.push(
      before === null
        ? `⚠️ O grupo tinha zerado o pool — agora volta para o tier **${tier}**.`
        : `⚠️ Entrou task de um tier que o grupo já tinha fechado: o tier atual volta de **${TIER_LABEL[TIERS[before - 1]]}** para **${tier}**.`,
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
 * Avisa no Discord o que a sync trouxe de novo. Nunca lanca: quando isto roda,
 * as tasks ja estao no banco, e o cron nao deve aparecer como falho so porque
 * o aviso nao saiu. O preco e que um aviso perdido nao volta — no dia
 * seguinte a task ja nao e nova. O erro fica no log.
 *
 * Devolve o que aconteceu, para o log.
 */
async function notify(env: Env, result: SyncResult): Promise<string> {
  const tasks = result.new_tasks ?? []

  if (!env.DISCORD_WEBHOOK_URL) return 'sem webhook'
  if (tasks.length === 0) return 'nada novo'
  // Banco que estava vazio (primeira carga, depois de um reset): seriam as ~1000
  // tasks de uma vez. Isso nao e novidade, e so o pool nascendo.
  if (result.total === result.inserted) return 'carga inicial, sem aviso'

  try {
    await postToDiscord(env.DISCORD_WEBHOOK_URL, discordMessage(summary(result, tasks), tasks))
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
  return JSON.stringify({ inserted, updated, total, tier_before, tier_after, discord })
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
    discordMessage(
      ['🧪 **Teste do aviso** — nada mudou no pool. Quando entrar task nova, fica assim:'],
      sample,
    ),
  )
  return 'aviso de teste enviado'
}

export default {
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    try {
      console.log(`[${controller.cron}] sync ok: ${await run(env)}`)
    } catch (err) {
      console.error(`[${controller.cron}] sync falhou: ${err instanceof Error ? err.message : err}`)
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
