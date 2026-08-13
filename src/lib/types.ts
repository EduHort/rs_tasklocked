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
   * Fica ao lado da `active` e nao mexe no pool das 990. null quando nao ha.
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
  /** null quando o grupo concluiu as 990 tasks */
  current_tier: Tier | null
  progress: TierProgress[]
  completed_total: number
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
   * Todas as conclusoes desta task, em ordem. A primeira e sempre a que tirou a
   * task do pool (`extra: false`); as demais sao as extras.
   */
  completions: Completion[]
  /** true se quem esta olhando ja fez esta task, no pool ou de extra */
  done_by_me: boolean
  /** true se esta e a task extra ATIVA de quem esta olhando */
  extra_active: boolean
}

export type CompletedPage = {
  /** quantas tasks sairam do pool — as extras nao entram aqui */
  total: number
  /** denominador do contador: quantos membros o grupo tem */
  member_total: number
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
}

export type PendingTaskPage = {
  total: number
  items: PendingTask[]
}

export type Session = {
  memberId: string
  token: string
  name: string
}

export const TIER_LABEL: Record<Tier, string> = {
  easy: 'Easy',
  medium: 'Medium',
  hard: 'Hard',
  elite: 'Elite',
  master: 'Master',
}
