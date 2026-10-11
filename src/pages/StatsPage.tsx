import { useEffect, useState, type ReactNode } from 'react'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { TaskImage } from '../components/TaskImage.tsx'
import { TierBadge } from '../components/TierBadge.tsx'
import { WeeklyChart } from '../components/WeeklyChart.tsx'
import { getStats, isAuthError } from '../lib/api.ts'
import { formatDay, formatDuration, formatShortDate } from '../lib/format.ts'
import type { GroupStats, MemberStats, Session, TimedCompletion } from '../lib/types.ts'

const DAY_MS = 24 * 60 * 60 * 1000

/**
 * Numeros da run: quanto tempo faz, o ritmo, quem fez mais e as tasks que mais
 * demoraram. Tudo vem pronto da `get_stats`; aqui so se formata.
 *
 * Carrega uma vez ao abrir, sem polling: nada aqui precisa estar ao vivo, e
 * quem quiser o numero de agora da F5.
 */
export function StatsPage({ session, onAuthError }: { session: Session; onAuthError: () => void }) {
  const [stats, setStats] = useState<GroupStats | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    getStats(session.token)
      .then((s) => alive && setStats(s))
      .catch((err) => {
        if (isAuthError(err)) {
          onAuthError()
          return
        }
        if (alive) setError(err instanceof Error ? err.message : 'Falha ao carregar as estatísticas.')
      })
    return () => {
      alive = false
    }
  }, [session.token, onAuthError])

  return (
    // w-full: dentro do flex-col do App, o mx-auto faz o main medir pelo
    // conteudo, e o grid de cards empurraria a pagina para fora da tela.
    <main className="mx-auto flex w-full max-w-5xl flex-col gap-6 px-5 py-6">
      <h1 className="text-sm font-bold uppercase tracking-widest text-muted">Estatísticas</h1>

      {error && <ErrorBanner message={error} onClose={() => setError(null)} />}

      {!stats ? (
        !error && <p className="text-sm text-muted">carregando…</p>
      ) : !stats.started_at ? (
        <p className="text-sm text-muted">
          Ninguém pegou nenhuma task ainda. Os números aparecem aqui assim que a run começar.
        </p>
      ) : (
        <StatsBody stats={stats} startedAt={stats.started_at} />
      )}
    </main>
  )
}

function StatsBody({ stats, startedAt }: { stats: GroupStats; startedAt: string }) {
  const n = (v: number) => v.toLocaleString('pt-BR')

  const elapsedDays = (Date.now() - new Date(startedAt).getTime()) / DAY_MS
  const remaining = stats.task_total - stats.pool_completed
  // Media desde o comeco. O piso de 1 dia evita que a primeira task, concluida
  // minutos depois de a run comecar, vire um ritmo de centenas por dia.
  const pace = stats.pool_completed / Math.max(1, elapsedDays)
  const pct = stats.task_total ? (stats.pool_completed / stats.task_total) * 100 : 0

  // Previsao ingenua de proposito: o ritmo desde o comeco, mantido ate o fim.
  // Os tiers de cima sao mais lentos, entao a data real vem depois — a nota no
  // rodape avisa.
  const eta =
    remaining <= 0
      ? 'acabou'
      : pace > 0
        ? new Date(Date.now() + (remaining / pace) * DAY_MS).toLocaleDateString('pt-BR', {
            month: 'short',
            year: 'numeric',
          })
        : '—'

  const streak = stats.longest_streak

  return (
    <>
      <section className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Tile label="Dias desde o começo" value={n(Math.floor(elapsedDays))}>
          desde {new Date(startedAt).toLocaleDateString('pt-BR')}
        </Tile>
        <Tile label="Pool concluído" value={n(stats.pool_completed)}>
          de {n(stats.task_total)} · {pct.toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%
        </Tile>
        <Tile label="Extras feitas" value={n(stats.extra_completed)}>
          repetições de tasks do grupo
        </Tile>
        <Tile label="Ritmo" value={`${pace.toLocaleString('pt-BR', { maximumFractionDigits: 1 })}/dia`}>
          do pool, desde o começo
        </Tile>
        <Tile label="Previsão de término" value={eta}>
          {remaining > 0
            ? pace > 0
              ? `nesse ritmo · faltam ${n(remaining)}`
              : 'nenhuma task do pool concluída ainda'
            : 'o pool inteiro foi concluído'}
        </Tile>
        <Tile label="Melhor dia" value={stats.best_day ? n(stats.best_day.count) : '—'}>
          {stats.best_day ? `tasks em ${formatDay(stats.best_day.day)}` : 'nenhuma conclusão ainda'}
        </Tile>
        <Tile
          label="Sequência atual"
          value={`${n(stats.current_streak)} ${stats.current_streak === 1 ? 'dia' : 'dias'}`}
        >
          {streak && streak.days > 0
            ? stats.current_streak >= streak.days
              ? 'seguidos com task — é o recorde'
              : `seguidos com task · recorde: ${n(streak.days)}`
            : 'seguidos com task'}
        </Tile>
        <Tile
          label="Tempo mediano"
          value={stats.median_secs === null ? '—' : formatDuration(stats.median_secs)}
        >
          entre pegar uma task e concluir
        </Tile>
      </section>

      <Section title="Quem fez mais" hint="pool + extras">
        <MemberRanking members={stats.members} me={stats.me} />
      </Section>

      <Section title="Tasks por semana" hint="pool + extras">
        <div className="rounded-lg border border-border bg-surface px-3 pt-3 pb-2">
          <WeeklyChart weeks={stats.weeks} />
        </div>
      </Section>

      <Section title="As que mais demoraram" hint="top 10">
        <TimedList items={stats.slowest} />
      </Section>

      <Section title="As mais rápidas" hint="top 5">
        <TimedList items={stats.fastest} />
      </Section>

      <p className="text-xs text-muted">
        Tempo de uma task = de quando a pessoa pegou até concluir, contando as noites e os dias sem
        jogar. As registradas direto pelo “Completar”, sem pegar antes, ficam fora dos tempos — mas
        contam nos totais. A previsão mantém o ritmo desde o começo até o fim; como os tiers
        de cima são mais lentos, o fim de verdade tende a vir depois.
      </p>
    </>
  )
}

function Tile({ label, value, children }: { label: string; value: string; children: ReactNode }) {
  return (
    // min-w-0: sem ele a coluna do grid cresce ate caber o valor inteiro, e no
    // celular duas colunas de "mai. de 2027" passam da largura da tela.
    <div className="min-w-0 rounded-lg border border-border bg-surface px-4 py-3">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-1 text-xl font-semibold break-words text-ink sm:text-2xl">{value}</p>
      <p className="mt-0.5 text-xs text-muted">{children}</p>
    </div>
  )
}

function Section({ title, hint, children }: { title: string; hint?: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="mb-3 flex items-baseline gap-2 text-sm font-bold uppercase tracking-widest text-muted">
        {title}
        {hint && <span className="text-xs font-normal normal-case tracking-normal">{hint}</span>}
      </h2>
      {children}
    </section>
  )
}

function MemberRanking({ members, me }: { members: MemberStats[]; me: string }) {
  const max = Math.max(1, ...members.map((m) => m.total))

  return (
    <ol className="divide-y divide-border overflow-hidden rounded-lg border border-border bg-surface">
      {members.map((m, i) => (
        <li key={m.id} className="flex items-center gap-3 px-3 py-2.5">
          <span className="w-5 shrink-0 text-right text-sm font-bold tabular-nums text-muted">
            {i + 1}
          </span>

          <div className="min-w-0 flex-1">
            <div className="flex items-baseline justify-between gap-3">
              <p className="truncate text-sm font-semibold">
                {m.name}
                {m.id === me && <span className="ml-2 text-xs font-normal text-accent">você</span>}
              </p>
              <p className="shrink-0 text-sm font-bold tabular-nums">{m.total}</p>
            </div>

            <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-bg">
              <div
                className="h-full rounded-full bg-chart"
                style={{ width: `${(m.total / max) * 100}%` }}
              />
            </div>

            <p className="mt-1 text-xs text-muted">
              {m.pool} do pool · {m.extra} extras
              {m.median_secs !== null && ` · mediana de ${formatDuration(m.median_secs)} por task`}
            </p>
          </div>
        </li>
      ))}
    </ol>
  )
}

function TimedList({ items }: { items: TimedCompletion[] }) {
  if (items.length === 0) {
    return <p className="text-sm text-muted">Nenhuma task cronometrada ainda.</p>
  }

  return (
    <ol className="divide-y divide-border overflow-hidden rounded-lg border border-border bg-surface">
      {items.map((it, i) => (
        <li key={`${it.task_id}-${it.member_name}`} className="flex items-center gap-3 px-3 py-2.5">
          <span className="w-5 shrink-0 text-right text-sm font-bold tabular-nums text-muted">
            {i + 1}
          </span>

          <TaskImage src={it.image_link} alt="" className="size-9 shrink-0" />

          <div className="min-w-0 flex-1">
            <p className="truncate text-sm" title={it.name}>
              {it.name}
            </p>
            <p className="truncate text-xs text-muted">
              {it.member_name}
              {it.extra && <span className="text-accent/75"> · extra</span>} ·{' '}
              {formatShortDate(it.assigned_at)} → {formatShortDate(it.completed_at)}
            </p>
          </div>

          {/* No celular o nome da task precisa do espaco mais que o tier. */}
          <span className="hidden shrink-0 sm:block">
            <TierBadge tier={it.tier} />
          </span>

          <span className="shrink-0 text-right text-sm font-bold tabular-nums sm:w-24">
            {formatDuration(it.secs)}
          </span>
        </li>
      ))}
    </ol>
  )
}
