import { TIER_LABEL, type Tier, type TierProgress } from '../lib/types.ts'

const BARS: Record<Tier, string> = {
  easy: 'bg-tier-easy',
  medium: 'bg-tier-medium',
  hard: 'bg-tier-hard',
  elite: 'bg-tier-elite',
  master: 'bg-tier-master',
}

export function TierProgressBar({
  progress,
  currentTier,
}: {
  progress: TierProgress[]
  currentTier: Tier | null
}) {
  return (
    <div className="grid gap-2 sm:grid-cols-5">
      {progress.map((p) => {
        const isCurrent = p.tier === currentTier
        const pct = p.total === 0 ? 0 : (p.completed / p.total) * 100
        const done = p.completed === p.total

        return (
          <div
            key={p.tier}
            className={`rounded-md border px-3 py-2 ${
              isCurrent ? 'border-accent bg-surface-2' : 'border-border bg-surface'
            }`}
          >
            <div className="flex items-baseline justify-between gap-2">
              <span
                className={`text-[11px] font-bold uppercase tracking-widest ${
                  isCurrent ? 'text-accent' : 'text-muted'
                }`}
              >
                {TIER_LABEL[p.tier]}
              </span>
              <span className="text-xs tabular-nums text-muted">
                {p.completed}/{p.total}
              </span>
            </div>

            <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-bg">
              <div
                className={`h-full rounded-full transition-[width] duration-500 ${BARS[p.tier]}`}
                style={{ width: `${pct}%` }}
              />
            </div>

            {done && <p className="mt-1 text-[11px] text-tier-easy">completo</p>}
            {!done && p.active > 0 && (
              <p className="mt-1 text-[11px] text-muted">{p.active} em andamento</p>
            )}
          </div>
        )
      })}
    </div>
  )
}
