import { useCallback, useEffect, useState } from 'react'
import { Button } from '../components/Button.tsx'
import { ConfirmDialog } from '../components/ConfirmDialog.tsx'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { TaskImage } from '../components/TaskImage.tsx'
import { TierBadge } from '../components/TierBadge.tsx'
import { isAuthError, listCompleted, takeExtraTask } from '../lib/api.ts'
import { formatDateTime } from '../lib/format.ts'
import type { CompletedEntry, Session } from '../lib/types.ts'

const PAGE = 50

/**
 * O que o grupo ja tirou do pool — uma linha por task, mais recentes primeiro.
 *
 * Cada linha traz o contador de quantas PESSOAS do grupo ja fizeram aquela
 * task (n/total de membros) e o botao de pegar a task como EXTRA: repetir uma
 * concluida, ao lado da task normal. A extra nao mexe nas 990, so sobe o
 * contador quando concluida (no board).
 */
export function CompletedPage({
  session,
  onAuthError,
}: {
  session: Session
  onAuthError: () => void
}) {
  const [items, setItems] = useState<CompletedEntry[]>([])
  const [total, setTotal] = useState(0)
  const [memberTotal, setMemberTotal] = useState(0)
  const [hasActiveExtra, setHasActiveExtra] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState<CompletedEntry | null>(null)
  const [busy, setBusy] = useState(false)

  const loadPage = useCallback(
    async (offset: number) => {
      setLoading(true)
      try {
        const page = await listCompleted(session.token, PAGE, offset)
        setTotal(page.total)
        setMemberTotal(page.member_total)
        setHasActiveExtra(page.has_active_extra)
        setItems((prev) => (offset === 0 ? page.items : [...prev, ...page.items]))
        setError(null)
      } catch (err) {
        if (isAuthError(err)) {
          onAuthError()
          return
        }
        setError(err instanceof Error ? err.message : 'Falha ao carregar a lista.')
      } finally {
        setLoading(false)
      }
    },
    [session.token, onAuthError],
  )

  useEffect(() => {
    void loadPage(0)
  }, [loadPage])

  async function takeExtra(entry: CompletedEntry) {
    setBusy(true)
    try {
      await takeExtraTask(session.token, entry.task_id)
      // Atualiza no lugar em vez de refazer a busca: mantem tudo o que ja foi
      // carregado e a posicao do scroll.
      setHasActiveExtra(true)
      setItems((prev) =>
        prev.map((it) => (it.task_id === entry.task_id ? { ...it, extra_active: true } : it)),
      )
      setError(null)
    } catch (err) {
      if (isAuthError(err)) {
        onAuthError()
        return
      }
      setError(err instanceof Error ? err.message : 'Não deu para pegar a task extra.')
    } finally {
      setConfirming(null)
      setBusy(false)
    }
  }

  return (
    <main className="mx-auto flex max-w-5xl flex-col gap-4 px-5 py-6">
      <header className="flex items-baseline justify-between gap-3">
        <h1 className="text-sm font-bold uppercase tracking-widest text-muted">
          Tasks concluídas
        </h1>
        <span className="text-sm text-muted">{total} de 990</span>
      </header>

      {error && <ErrorBanner message={error} onClose={() => setError(null)} />}

      {items.length === 0 && !loading ? (
        <p className="text-sm text-muted">
          O grupo ainda não concluiu nenhuma task. Elas aparecem aqui conforme forem saindo.
        </p>
      ) : (
        <ul className="divide-y divide-border overflow-hidden rounded-lg border border-border bg-surface">
          {items.map((entry) => {
            const everyone = entry.completed_count >= memberTotal

            return (
              <li key={entry.id} className="flex items-center gap-3 px-3 py-2.5">
                <TaskImage src={entry.image_link} alt="" className="size-9 shrink-0" />

                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm" title={entry.name}>
                    {entry.name}
                  </p>

                  {/* Uma entrada por pessoa que fez a task: quem a tirou do pool
                      primeiro, depois quem a repetiu de extra. */}
                  <div className="flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-muted">
                    {entry.completions.map((c) => (
                      <span key={c.name} className={c.extra ? 'text-accent/75' : undefined}>
                        {c.name} · {formatDateTime(c.completed_at)}
                        {c.extra && ' · extra'}
                      </span>
                    ))}
                  </div>
                </div>

                <span
                  className={`shrink-0 rounded border px-2 py-0.5 text-xs font-bold tabular-nums
                    ${everyone ? 'border-ok text-ok' : 'border-border text-muted'}`}
                >
                  {entry.completed_count}/{memberTotal}
                </span>

                <TierBadge tier={entry.tier} className="shrink-0" />

                <ExtraButton
                  entry={entry}
                  everyone={everyone}
                  hasActiveExtra={hasActiveExtra}
                  busy={busy}
                  onClick={() => setConfirming(entry)}
                />
              </li>
            )
          })}
        </ul>
      )}

      {items.length < total && (
        <Button variant="ghost" loading={loading} onClick={() => void loadPage(items.length)}>
          Carregar mais
        </Button>
      )}

      <ConfirmDialog
        open={confirming !== null}
        title="Pegar como task extra?"
        message={`“${confirming?.name ?? ''}” entra no seu board ao lado da sua task normal, e não dá para devolver: concluir é a única saída, e você só pode ter uma extra por vez. Ela não mexe no progresso das 990 — ao concluir, você entra no contador dessa task.`}
        confirmLabel="Pegar extra"
        busy={busy}
        onConfirm={() => confirming && void takeExtra(confirming)}
        onCancel={() => setConfirming(null)}
      />
    </main>
  )
}

/**
 * Botao de pegar a extra. Cada motivo de bloqueio tem o seu texto — a RPC
 * recusaria de qualquer jeito, mas dizer o porque antes do clique e melhor do
 * que devolver um erro depois.
 */
function ExtraButton({
  entry,
  everyone,
  hasActiveExtra,
  busy,
  onClick,
}: {
  entry: CompletedEntry
  everyone: boolean
  hasActiveExtra: boolean
  busy: boolean
  onClick: () => void
}) {
  if (entry.extra_active) {
    return (
      <span className="shrink-0 text-xs font-semibold text-accent" title="Está no seu board agora">
        sua extra
      </span>
    )
  }

  const blocked = entry.done_by_me
    ? 'Você já fez essa task.'
    : everyone
      ? 'Todo mundo do grupo já fez essa task.'
      : hasActiveExtra
        ? 'Você já tem uma task extra. Conclua ou devolva ela primeiro.'
        : null

  return (
    <Button
      variant="ghost"
      className="shrink-0"
      disabled={blocked !== null || busy}
      title={blocked ?? 'Repetir essa task ao lado da sua normal — sem devolver depois'}
      onClick={onClick}
    >
      Pegar extra
    </Button>
  )
}
