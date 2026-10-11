import { useState } from 'react'
import { formatDay } from '../lib/format.ts'

type Week = { week: string; pool: number; extra: number }

/**
 * Topo do eixo: o maior valor arredondado para cima na sua casa decimal
 * (61 -> 70, 130 -> 200, 8 -> 8). Arredondar para 1/2/5 jogaria 61 em 100 e
 * deixaria quase metade do grafico vazia.
 */
function niceCeil(n: number): number {
  if (n <= 0) return 1
  const unit = 10 ** Math.floor(Math.log10(n))
  return Math.ceil(n / unit) * unit
}

/**
 * Colunas de tasks concluidas por semana (pool + extras). Uma serie so, entao
 * sem legenda — o titulo da secao ja diz o que e. O detalhe (quanto foi pool,
 * quanto foi extra) fica no tooltip, que abre no hover e no foco do teclado.
 *
 * O unico numero escrito no grafico e o da semana recorde; o resto sai do eixo
 * e do tooltip.
 */
export function WeeklyChart({ weeks }: { weeks: Week[] }) {
  const [hovered, setHovered] = useState<number | null>(null)

  const totals = weeks.map((w) => w.pool + w.extra)
  const max = Math.max(0, ...totals)
  const top = niceCeil(max)
  const best = totals.indexOf(max)
  const last = weeks.length - 1

  const tip = hovered === null ? null : weeks[hovered]
  // Desloca o tooltip na mesma proporcao da posicao da coluna: na primeira ele
  // abre para a direita, na ultima para a esquerda, e nunca sai do grafico.
  const tipPct = hovered === null ? 0 : ((hovered + 0.5) / weeks.length) * 100

  return (
    <div className="relative h-44">
      {/* Area de plotagem: grade e colunas medem a altura na mesma caixa. */}
      <div className="absolute top-5 right-0 bottom-6 left-8">
        {/* Grade: tres linhas finas, a do zero um pouco mais forte. */}
        {(top % 2 === 0 ? [0, top / 2, top] : [0, top]).map((tick) => (
          <div
            key={tick}
            className={`absolute inset-x-0 border-t ${tick === 0 ? 'border-border' : 'border-border/50'}`}
            style={{ bottom: `${(tick / top) * 100}%` }}
          >
            <span
              className="absolute -left-8 w-6 -translate-y-1/2 text-right text-[10px] tabular-nums
                text-muted"
            >
              {tick}
            </span>
          </div>
        ))}
      </div>

      <div className="absolute top-5 right-0 bottom-6 left-8 flex items-end gap-[2px]">
        {weeks.map((w, i) => {
          const total = totals[i]
          return (
            <button
              key={w.week}
              type="button"
              aria-label={`Semana de ${formatDay(w.week)}: ${total} tasks, ${w.pool} do pool e ${w.extra} extras`}
              onPointerEnter={() => setHovered(i)}
              onPointerLeave={() => setHovered(null)}
              onFocus={() => setHovered(i)}
              onBlur={() => setHovered(null)}
              className="group flex h-full min-w-0 flex-1 cursor-default flex-col items-center
                justify-end outline-none"
            >
              {i === best && max > 0 && (
                <span className="mb-1 text-[11px] font-semibold text-ink">{total}</span>
              )}
              <span
                className={`block w-full max-w-6 rounded-t-[4px] transition-colors ${
                  hovered === i ? 'bg-accent' : 'bg-chart'
                } group-focus-visible:ring-2 group-focus-visible:ring-accent`}
                style={{ height: `${(total / top) * 100}%` }}
              />
            </button>
          )
        })}
      </div>

      {/* Eixo X: so a primeira e a semana atual. */}
      <div className="absolute right-0 bottom-0 left-8 flex justify-between text-[10px] text-muted">
        <span>{weeks.length > 0 && formatDay(weeks[0].week)}</span>
        <span>esta semana</span>
      </div>

      {tip && (
        <div
          role="tooltip"
          className="pointer-events-none absolute top-0 z-10 rounded-md border border-border
            bg-surface-2 px-3 py-2 text-xs whitespace-nowrap shadow-lg"
          style={{
            left: `calc(2rem + (100% - 2rem) * ${tipPct / 100})`,
            transform: `translate(-${tipPct}%, -100%)`,
          }}
        >
          <p className="text-sm font-bold text-ink">{tip.pool + tip.extra} tasks</p>
          <p className="text-muted">
            {tip.pool} do pool · {tip.extra} extras
          </p>
          <p className="text-muted">
            semana de {formatDay(tip.week)}
            {hovered === last && ' (em andamento)'}
          </p>
        </div>
      )}
    </div>
  )
}
