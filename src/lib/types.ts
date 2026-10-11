export const TIERS = ['easy', 'medium', 'hard', 'elite', 'master'] as const
export type Tier = (typeof TIERS)[number]

export type Verification =
  | { method: 'collection-log'; itemIds: number[]; count?: number }
  | { method: 'achievement-diary'; region: string; difficulty: string }
  | { method: 'skill'; experience: number; count?: number }

export type Task = {
  id: string
  tier: Tier
  name: string
  short_name: string | null
  tip: string
  wiki_link: string
  image_link: string
  display_item_id: number
  verification: Verification | null
  tags: string[] | null
}

export type ActiveAssignment = {
  assignment_id: string
  assigned_at: string
  task: Task
}

export type Member = {
  id: string
  name: string
  created_at: string
  last_seen_at: string
  /** null quando o membro ainda nao gerou task */
  active: ActiveAssignment | null
  /**
   * Task EXTRA: uma que o grupo JA concluiu e o membro escolheu repetir.
   * Fica ao lado da `active` e nao mexe no pool. null quando nao ha.
   */
  extra: ActiveAssignment | null
}

export type TierProgress = {
  tier: Tier
  tier_order: number
  total: number
  completed: number
  active: number
}

export type GroupState = {
  /** id do membro dono do token — quem esta olhando a tela */
  me: string
  members: Member[]
  /** null quando o grupo concluiu todas as tasks do pool */
  current_tier: Tier | null
  progress: TierProgress[]
  completed_total: number
  /**
   * Tamanho do pool hoje — o denominador de "X de Y". Vem do banco em vez de
   * ser fixo no codigo: o task-list.json muda de tamanho quando a lista do jogo
   * e atualizada, e o `npm run seed` sozinho ja acerta a tela.
   */
  task_total: number
}

/** Uma pessoa que fez uma task — seja tirando-a do pool, seja repetindo de extra. */
export type Completion = {
  name: string
  completed_at: string
  /** false = tirou a task do pool · true = fez como task extra */
  extra: boolean
}

export type CompletedEntry = {
  /** id do assignment que tirou a task do pool — chave da linha na lista */
  id: string
  /** id da TASK, que e o que `takeExtraTask` recebe */
  task_id: string
  completed_at: string
  /** quem tirou a task do pool */
  member_name: string
  tier: Tier
  name: string
  short_name: string | null
  wiki_link: string
  image_link: string
  display_item_id: number
  /** quantas PESSOAS do grupo ja fizeram esta task. 1 = so quem tirou do pool. */
  completed_count: number
  /**
   * Todas as conclusoes desta task, em ordem cronologica. A que tirou a task do
   * pool (`extra: false`) nao e necessariamente a primeira: da para pegar de
   * extra a task ativa de outra pessoa e concluir antes dela.
   */
  completions: Completion[]
  /** true se quem esta olhando ja fez esta task, no pool ou de extra */
  done_by_me: boolean
  /** true se esta e a task extra ATIVA de quem esta olhando */
  extra_active: boolean
}

export type CompletedPage = {
  /** quantas tasks sairam do pool — as extras nao entram aqui. Ignora o filtro. */
  total: number
  /** quantas passam no filtro da busca — e o que a paginacao usa */
  match_total: number
  /** tamanho do pool hoje — o mesmo `task_total` do `GroupState` */
  task_total: number
  /** denominador do contador: quantos membros o grupo tem */
  member_total: number
  /** todo mundo do grupo, em ordem de entrada — as opcoes do filtro "feitas por" */
  members: { id: string; name: string }[]
  /** true se quem olha ja esta com uma extra (so pode haver uma por vez) */
  has_active_extra: boolean
  items: CompletedEntry[]
}

/**
 * Uma task que o grupo ainda nao concluiu — item da tela "A fazer".
 * Nao e um `Task` completo: `list_pending` deixa de fora `verification` e
 * `tags`, que a lista nao usa.
 */
export type PendingTask = {
  id: string
  tier: Tier
  tier_order: number
  name: string
  short_name: string | null
  tip: string
  wiki_link: string
  image_link: string
  display_item_id: number
  /** true quando a task esta ativa com alguem agora */
  taken: boolean
  /** nome de quem esta com ela, ou null se estiver livre */
  holder_name: string | null
  /**
   * true se quem esta com ela e quem esta olhando. Use isto, nao o nome: o
   * nome pode mudar, e a lista pode ter chegado com o antigo.
   */
  mine: boolean
  /** true se esta e a task extra ATIVA de quem esta olhando */
  extra_active: boolean
  /** true se quem esta olhando ja fez esta task de extra */
  extra_done: boolean
}

export type PendingTaskPage = {
  total: number
  /** true se quem olha ja esta com uma extra (so pode haver uma ativa por vez) */
  has_active_extra: boolean
  items: PendingTask[]
}

/** Uma task concluida com o tempo que levou — linha dos rankings da /stats. */
export type TimedCompletion = {
  task_id: string
  name: string
  tier: Tier
  image_link: string
  member_name: string
  assigned_at: string
  completed_at: string
  /** de pegar a task ate concluir */
  secs: number
  /** true = feita como extra */
  extra: boolean
}

export type MemberStats = {
  id: string
  name: string
  /** tasks que essa pessoa tirou do pool */
  pool: number
  /** tasks que repetiu de extra */
  extra: number
  total: number
  /** null quando nao ha nenhuma task cronometrada (so registros diretos) */
  median_secs: number | null
}

export type GroupStats = {
  me: string
  /** a primeira task que alguem pegou. null = o grupo ainda nao pegou nenhuma */
  started_at: string | null
  task_total: number
  pool_completed: number
  extra_completed: number
  /** dias (no fuso de Brasilia) com pelo menos uma conclusao */
  active_days: number
  best_day: { day: string; count: number } | null
  longest_streak: { days: number; first_day: string; last_day: string } | null
  current_streak: number
  median_secs: number | null
  /** mais tasks feitas primeiro */
  members: MemberStats[]
  /** top 10. Registros diretos (sem pegar antes) ficam de fora. */
  slowest: TimedCompletion[]
  /** top 5 */
  fastest: TimedCompletion[]
  /** uma por semana, segunda a segunda, desde o comeco — inclusive as vazias */
  weeks: { week: string; pool: number; extra: number }[]
}

export type Session = {
  memberId: string
  token: string
  name: string
}

/** Resposta do login: entrou, ou o nome e novo e a conta ainda nao foi criada. */
export type JoinResult =
  | { status: 'joined'; session: Session }
  | {
      status: 'new'
      /** quem ja esta no grupo, em ordem de entrada */
      members: string[]
    }

export const TIER_LABEL: Record<Tier, string> = {
  easy: 'Easy',
  medium: 'Medium',
  hard: 'Hard',
  elite: 'Elite',
  master: 'Master',
}
