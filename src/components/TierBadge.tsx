import { TIER_LABEL, type Tier } from '../lib/types.ts'

const COLORS: Record<Tier, string> = {
  easy: 'text-tier-easy border-tier-easy',
  medium: 'text-tier-medium border-tier-medium',
  hard: 'text-tier-hard border-tier-hard',
  elite: 'text-tier-elite border-tier-elite',
  master: 'text-tier-master border-tier-master',
}

export function TierBadge({ tier, className = '' }: { tier: Tier; className?: string }) {
  return (
    <span
      className={`inline-block rounded border px-2 py-0.5 text-[11px] font-bold uppercase
        tracking-widest ${COLORS[tier]} ${className}`}
    >
      {TIER_LABEL[tier]}
    </span>
  )
}
