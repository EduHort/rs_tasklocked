import { useCallback, useEffect, useState } from 'react'
import { Button } from '../components/Button.tsx'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { TaskImage } from '../components/TaskImage.tsx'
import { TierBadge } from '../components/TierBadge.tsx'
import { isAuthError, listCompleted } from '../lib/api.ts'
import { formatDateTime } from '../lib/format.ts'
import type { CompletedEntry, Session } from '../lib/types.ts'

const PAGE = 50

export function CompletedPage({
  session,
  onAuthError,
}: {
  session: Session
  onAuthError: () => void
}) {
  const [items, setItems] = useState<CompletedEntry[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const loadPage = useCallback(
    async (offset: number) => {
      setLoading(true)
      try {
        const page = await listCompleted(session.token, PAGE, offset)
        setTotal(page.total)
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
          {items.map((entry) => (
            <li key={entry.id} className="flex items-center gap-3 px-3 py-2.5">
              <TaskImage src={entry.image_link} alt="" className="size-9 shrink-0" />

              <div className="min-w-0 flex-1">
                <p className="truncate text-sm">{entry.name}</p>
                <p className="text-xs text-muted">
                  {entry.member_name} · {formatDateTime(entry.completed_at)}
                </p>
              </div>

              <TierBadge tier={entry.tier} className="shrink-0" />
            </li>
          ))}
        </ul>
      )}

      {items.length < total && (
        <Button variant="ghost" loading={loading} onClick={() => void loadPage(items.length)}>
          Carregar mais
        </Button>
      )}
    </main>
  )
}
