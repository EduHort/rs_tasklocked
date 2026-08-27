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
 */

const UPSTREAM =
  'https://raw.githubusercontent.com/OSRS-Taskman/collection-log-master/main/src/main/resources/com/collectionlogmaster/task-list.json'

const TIERS = ['easy', 'medium', 'hard', 'elite', 'master'] as const

type Env = {
  SUPABASE_URL: string
  SUPABASE_ANON_KEY: string
  SYNC_SECRET: string
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

async function sync(env: Env): Promise<string> {
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

  return body
}

export default {
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    try {
      const result = await sync(env)
      console.log(`[${controller.cron}] sync ok: ${result}`)
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
   *
   * Protegido pelo mesmo segredo. Nao e uma defesa forte contra quem descobrir
   * a URL e tiver paciencia — mas o pior caso e um upsert da lista publica que
   * o cron ja faria sozinho todo dia.
   */
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.headers.get('authorization') !== `Bearer ${env.SYNC_SECRET}`) {
      return new Response('nao autorizado\n', { status: 401 })
    }
    try {
      return new Response(`${await sync(env)}\n`)
    } catch (err) {
      return new Response(`${err instanceof Error ? err.message : err}\n`, { status: 500 })
    }
  },
}
