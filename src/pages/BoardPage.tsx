import { useState } from 'react'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { ExtraTaskCard } from '../components/ExtraTaskCard.tsx'
import { MemberCard } from '../components/MemberCard.tsx'
import { MyTaskCard } from '../components/MyTaskCard.tsx'
import { TierProgressBar } from '../components/TierProgressBar.tsx'
import { useGroupState } from '../hooks/useGroupState.ts'
import { completeExtraTask, completeTask, rollTask } from '../lib/api.ts'
import type { Session } from '../lib/types.ts'

export function BoardPage({
  session,
  onAuthError,
}: {
  session: Session
  onAuthError: () => void
}) {
  const { state, loading, error, refresh } = useGroupState(session.token, onAuthError)
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  const me = state?.members.find((m) => m.id === state.me) ?? null
  const others = state?.members.filter((m) => m.id !== state.me) ?? []

  /** Roda a acao, mostra o erro traduzido e sincroniza o board na hora. */
  async function run(action: () => Promise<unknown>) {
    setBusy(true)
    setActionError(null)
    try {
      await action()
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Algo deu errado.')
    } finally {
      await refresh()
      setBusy(false)
    }
  }

  if (loading && !state) {
    return <p className="mx-auto max-w-5xl px-5 py-10 text-sm text-muted">carregando…</p>
  }

  return (
    <main className="mx-auto flex max-w-5xl flex-col gap-6 px-5 py-6">
      {state && (
        <TierProgressBar progress={state.progress} currentTier={state.current_tier} />
      )}

      {(error || actionError) && (
        <ErrorBanner
          message={actionError ?? error ?? ''}
          onClose={() => setActionError(null)}
        />
      )}

      <MyTaskCard
        name={session.name}
        active={me?.active ?? null}
        currentTier={state?.current_tier ?? null}
        busy={busy}
        onRoll={() => void run(() => rollTask(session.token))}
        onComplete={() => void run(() => completeTask(session.token))}
      />

      {/* So aparece com uma extra pegue: quem quer uma escolhe em /completed. */}
      {me?.extra && (
        <ExtraTaskCard
          extra={me.extra}
          busy={busy}
          onComplete={() => void run(() => completeExtraTask(session.token))}
        />
      )}

      <section>
        <h2 className="mb-3 text-sm font-bold uppercase tracking-widest text-muted">
          Tasks do grupo
        </h2>

        {others.length === 0 ? (
          <p className="text-sm text-muted">
            Ninguém mais entrou ainda. Passe o código do grupo pros seus amigos.
          </p>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2">
            {others.map((member) => (
              <MemberCard key={member.id} member={member} />
            ))}
          </div>
        )}
      </section>

      {state && (
        <p className="text-xs text-muted">
          {state.completed_total} de 990 tasks concluídas pelo grupo.
        </p>
      )}
    </main>
  )
}
