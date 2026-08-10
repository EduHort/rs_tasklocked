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

export type CompletedEntry = {
  id: string
  completed_at: string
  member_name: string
  tier: Tier
  name: string
  short_name: string | null
  wiki_link: string
  image_link: string
  display_item_id: number
}

export type CompletedPage = {
  total: number
  items: CompletedEntry[]
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
