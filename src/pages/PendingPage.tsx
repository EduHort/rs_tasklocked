import { useCallback, useEffect, useRef, useState } from 'react'
import { Button } from '../components/Button.tsx'
import { ConfirmDialog } from '../components/ConfirmDialog.tsx'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { FilterPill } from '../components/FilterPill.tsx'
import { TaskImage } from '../components/TaskImage.tsx'
import { TierBadge } from '../components/TierBadge.tsx'
import { completeTaskById, isAuthError, listPending, takeExtraTask } from '../lib/api.ts'
import { TIER_LABEL, TIERS, type PendingTask, type Session, type Tier } from '../lib/types.ts'

const PAGE = 50

/**
 * Todas as tasks que o grupo ainda nao concluiu, com um botao para marcar cada
 * uma como feita sem precisar sortea-la antes — util para registrar o que ja
 * foi feito no jogo. Nao ha gating de tier aqui: a lista mostra o pool inteiro.
 *
 * Concluir a task de OUTRA pessoa continua bloqueado (o botao fica desativado,
 * e a RPC recusaria de qualquer jeito) — mas da para PEGA-LA como extra e fazer
 * junto, sem esperar aquela pessoa concluir. Task livre nunca vale de extra:
 * seria um atalho para furar o gating de tier.
 */
export function PendingPage({
  session,
  onAuthError,
}: {
  session: Session
  onAuthError: () => void
}) {
  const [items, setItems] = useState<PendingTask[]>([])
  const [total, setTotal] = useState(0)
  const [nextOffset, setNextOffset] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [tier, setTier] = useState<Tier | null>(null)
  const [search, setSearch] = useState('')
  const [query, setQuery] = useState('')
  const [hasActiveExtra, setHasActiveExtra] = useState(false)
  const [confirming, setConfirming] = useState<{
    task: PendingTask
    action: 'complete' | 'take'
  } | null>(null)
  const [busy, setBusy] = useState(false)

  // Descarta resposta de filtro que o usuario ja trocou (a antiga pode chegar
  // depois da nova e sobrescrever a lista certa).
  const requestId = useRef(0)

  useEffect(() => {
    const id = setTimeout(() => setQuery(search.trim()), 300)
    return () => clearTimeout(id)
  }, [search])

  const loadPage = useCallback(
    async (offset: number) => {
      const id = ++requestId.current
      setLoading(true)
      try {
        const page = await listPending(session.token, {
          limit: PAGE,
          offset,
          tier,
          search: query,
        })
        if (id !== requestId.current) return
        setTotal(page.total)
        setHasActiveExtra(page.has_active_extra)
        setItems((prev) => (offset === 0 ? page.items : [...prev, ...page.items]))
        setNextOffset(offset + page.items.length)
        setError(null)
      } catch (err) {
        if (isAuthError(err)) {
          onAuthError()
          return
        }
        if (id !== requestId.current) return
        setError(err instanceof Error ? err.message : 'Falha ao carregar a lista.')
      } finally {
        if (id === requestId.current) setLoading(false)
      }
    },
    [session.token, onAuthError, tier, query],
  )

  // Recarrega do zero sempre que o tier ou a busca mudam.
  useEffect(() => {
    void loadPage(0)
  }, [loadPage])

  async function complete(task: PendingTask) {
    setBusy(true)
    try {
      await completeTaskById(session.token, task.id)
      // Tira da lista no lugar de refazer a busca: mantem tudo o que ja foi
      // carregado. O offset anda junto para nao pular item no "carregar mais".
      setItems((prev) => prev.filter((t) => t.id !== task.id))
      setTotal((n) => Math.max(0, n - 1))
      setNextOffset((n) => Math.max(0, n - 1))
      setError(null)
    } catch (err) {
      if (isAuthError(err)) {
        onAuthError()
        return
      }
      setError(err instanceof Error ? err.message : 'Não deu para concluir a task.')
    } finally {
      setConfirming(null)
      setBusy(false)
    }
  }

  /**
   * Pega a task de extra. Ela CONTINUA na lista de pendentes: o pool nao muda,
   * quem esta com ela segue sendo o dono. So a marca da linha muda.
   */
  async function takeExtra(task: PendingTask) {
    setBusy(true)
    try {
      await takeExtraTask(session.token, task.id)
      setHasActiveExtra(true)
      setItems((prev) =>
        prev.map((t) => (t.id === task.id ? { ...t, extra_active: true } : t)),
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
        <h1 className="text-sm font-bold uppercase tracking-widest text-muted">Tasks a fazer</h1>
        <span className="text-sm text-muted">{total} restantes</span>
      </header>

      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <div className="flex flex-wrap gap-1">
          <FilterPill active={tier === null} onClick={() => setTier(null)}>
            Todos
          </FilterPill>
          {TIERS.map((t) => (
            <FilterPill key={t} active={tier === t} onClick={() => setTier(t)}>
              {TIER_LABEL[t]}
            </FilterPill>
          ))}
        </div>

        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Buscar pelo nome…"
          autoComplete="off"
          className="rounded-md border border-border bg-surface px-3 py-1.5 text-sm outline-none
            focus:border-accent sm:ml-auto sm:w-64"
        />
      </div>

      {error && <ErrorBanner message={error} onClose={() => setError(null)} />}

      {items.length === 0 ? (
        <p className="text-sm text-muted">
          {loading
            ? 'carregando…'
            : query || tier
              ? 'Nenhuma task pendente com esse filtro.'
              : 'O grupo concluiu todas as tasks. Acabou.'}
        </p>
      ) : (
        <ul className="divide-y divide-border overflow-hidden rounded-lg border border-border bg-surface">
          {items.map((task) => {
            const mine = task.mine
            const lockedByOther = task.taken && !mine

            return (
              <li key={task.id} className="flex items-center gap-3 px-3 py-2.5">
                <TaskImage src={task.image_link} alt="" className="size-9 shrink-0" />

                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm" title={task.name}>
                    {task.name}
                  </p>
                  <p className="truncate text-xs text-muted">
                    {mine ? 'é a sua task ativa' : task.taken ? `com ${task.holder_name}` : 'livre'}
                    {task.extra_active && (
                      <span className="text-accent/75"> · sua extra</span>
                    )}
                    {task.extra_done && <span> · você já fez</span>}
                    {' · '}
                    <a
                      href={task.wiki_link}
                      target="_blank"
                      rel="noreferrer noopener"
                      className="text-accent underline underline-offset-2 hover:brightness-110"
                    >
                      wiki
                    </a>
                  </p>
                </div>

                <TierBadge tier={task.tier} className="shrink-0" />

                {/* Task de outra pessoa: concluir e dela, mas acompanhar de
                    extra e permitido. Livre nao entra: viraria atalho de tier. */}
                {lockedByOther && (
                  <ExtraButton
                    task={task}
                    hasActiveExtra={hasActiveExtra}
                    busy={busy}
                    onClick={() => setConfirming({ task, action: 'take' })}
                  />
                )}

                <Button
                  variant="ghost"
                  className="shrink-0"
                  disabled={lockedByOther || busy}
                  title={
                    lockedByOther
                      ? `${task.holder_name} está com essa task. Só quem está com ela pode concluir.`
                      : undefined
                  }
                  onClick={() => setConfirming({ task, action: 'complete' })}
                >
                  Completar
                </Button>
              </li>
            )
          })}
        </ul>
      )}

      {items.length > 0 && nextOffset < total && (
        <Button variant="ghost" loading={loading} onClick={() => void loadPage(nextOffset)}>
          Carregar mais
        </Button>
      )}

      <ConfirmDialog
        open={confirming !== null}
        title={confirming?.action === 'take' ? 'Pegar como task extra?' : 'Completar a task?'}
        message={
          confirming?.action === 'take'
            ? `“${confirming.task.name}” continua sendo a task de ${confirming.task.holder_name} — ela entra no seu board como extra, para vocês fazerem em paralelo. Não dá para devolver: concluir é a única saída, e você só pode ter uma extra por vez. Não mexe no progresso do grupo.`
            : `“${confirming?.task.name ?? ''}” sai do pool do grupo para sempre e vai para a lista de concluídas em seu nome.`
        }
        confirmLabel={confirming?.action === 'take' ? 'Pegar extra' : 'Completar'}
        busy={busy}
        onConfirm={() => {
          if (!confirming) return
          void (confirming.action === 'take'
            ? takeExtra(confirming.task)
            : complete(confirming.task))
        }}
        onCancel={() => setConfirming(null)}
      />
    </main>
  )
}

/**
 * Pegar de extra a task ativa de outra pessoa. Cada bloqueio diz o porque antes
 * do clique, em vez de deixar a RPC devolver o erro depois.
 */
function ExtraButton({
  task,
  hasActiveExtra,
  busy,
  onClick,
}: {
  task: PendingTask
  hasActiveExtra: boolean
  busy: boolean
  onClick: () => void
}) {
  if (task.extra_active) {
    return (
      <span className="shrink-0 text-xs font-semibold text-accent" title="Está no seu board agora">
        sua extra
      </span>
    )
  }

  const blocked = task.extra_done
    ? 'Você já fez essa task.'
    : hasActiveExtra
      ? 'Você já tem uma task extra. Conclua ou devolva ela primeiro.'
      : null

  return (
    <Button
      variant="ghost"
      className="shrink-0"
      disabled={blocked !== null || busy}
      title={blocked ?? `Fazer junto com ${task.holder_name}, como sua task extra`}
      onClick={onClick}
    >
      Pegar extra
    </Button>
  )
}
