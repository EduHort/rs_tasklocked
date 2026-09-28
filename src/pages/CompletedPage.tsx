import { useCallback, useEffect, useRef, useState } from 'react'
import { Button } from '../components/Button.tsx'
import { ConfirmDialog } from '../components/ConfirmDialog.tsx'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { FilterPill } from '../components/FilterPill.tsx'
import { TaskImage } from '../components/TaskImage.tsx'
import { TierBadge } from '../components/TierBadge.tsx'
import { completeExtraById, isAuthError, listCompleted, takeExtraTask } from '../lib/api.ts'
import { formatDateTime } from '../lib/format.ts'
import type { CompletedEntry, Session } from '../lib/types.ts'

const PAGE = 50

/**
 * O que o grupo ja tirou do pool — uma linha por task, mais recentes primeiro.
 *
 * Cada linha traz o contador de quantas PESSOAS do grupo ja fizeram aquela task
 * (n/total de membros) e duas acoes:
 *
 *   Completar   — registra na hora que voce fez aquela task. E o caminho de
 *                 quem concluiu a task de passagem: funciona mesmo com uma
 *                 extra ativa na mao, porque nao passa pelo estado "extra".
 *   Pegar extra — coloca a task no seu board ao lado da normal, para fazer
 *                 depois. Continua limitado a uma extra ativa por vez.
 *
 * Nenhuma das duas mexe no pool: as duas so sobem o contador de pessoas.
 *
 * Busca e filtros rodam no banco, nao na lista carregada: a lista e paginada,
 * e filtrar so o que ja chegou esconderia o que ainda nao chegou.
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
  const [matchTotal, setMatchTotal] = useState(0)
  const [nextOffset, setNextOffset] = useState(0)
  const [taskTotal, setTaskTotal] = useState(0)
  const [memberTotal, setMemberTotal] = useState(0)
  const [members, setMembers] = useState<{ id: string; name: string }[]>([])
  const [hasActiveExtra, setHasActiveExtra] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [query, setQuery] = useState('')
  /** true = so as que eu fiz · false = so as que eu nao fiz · null = todas */
  const [doneByMe, setDoneByMe] = useState<boolean | null>(null)
  /** id do membro: so as que ele fez · null = de qualquer pessoa */
  const [doneBy, setDoneBy] = useState<string | null>(null)
  const [confirming, setConfirming] = useState<{
    entry: CompletedEntry
    action: 'take' | 'complete'
  } | null>(null)
  const [busy, setBusy] = useState(false)

  const filtering = query !== '' || doneByMe !== null || doneBy !== null

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
        const page = await listCompleted(session.token, {
          limit: PAGE,
          offset,
          search: query,
          doneByMe,
          doneBy,
        })
        if (id !== requestId.current) return
        setTotal(page.total)
        setMatchTotal(page.match_total)
        setTaskTotal(page.task_total)
        setMemberTotal(page.member_total)
        setMembers(page.members)
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
    [session.token, onAuthError, query, doneByMe, doneBy],
  )

  // Recarrega do zero sempre que a busca ou um filtro mudam.
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

  /** Registra a conclusao na hora, com ou sem ter pegado a extra antes. */
  async function complete(entry: CompletedEntry) {
    setBusy(true)
    try {
      await completeExtraById(session.token, entry.task_id)
      // Atualiza no lugar, como o takeExtra. Se a task era a extra ativa, ela
      // deixa de ser — o board libera para pegar outra.
      if (entry.extra_active) setHasActiveExtra(false)
      if (doneByMe === false) {
        // No filtro "nao fiz" ela deixou de caber: sai da lista, e o offset
        // anda junto para nao pular item no "carregar mais".
        setItems((prev) => prev.filter((it) => it.task_id !== entry.task_id))
        setMatchTotal((n) => Math.max(0, n - 1))
        setNextOffset((n) => Math.max(0, n - 1))
      } else {
        setItems((prev) =>
          prev.map((it) =>
            it.task_id === entry.task_id
              ? {
                  ...it,
                  done_by_me: true,
                  extra_active: false,
                  completed_count: it.completed_count + 1,
                  completions: [
                    ...it.completions,
                    { name: session.name, completed_at: new Date().toISOString(), extra: true },
                  ],
                }
              : it,
          ),
        )
      }
      setError(null)
    } catch (err) {
      if (isAuthError(err)) {
        onAuthError()
        return
      }
      setError(err instanceof Error ? err.message : 'Não deu para registrar a conclusão.')
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
        <span className="text-sm text-muted">
          {filtering && `${matchTotal} no filtro · `}
          {total} de {taskTotal}
        </span>
      </header>

      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        <div className="flex flex-wrap gap-1">
          <FilterPill active={doneByMe === null} onClick={() => setDoneByMe(null)}>
            Todas
          </FilterPill>
          <FilterPill active={doneByMe === true} onClick={() => setDoneByMe(true)}>
            Já fiz
          </FilterPill>
          <FilterPill active={doneByMe === false} onClick={() => setDoneByMe(false)}>
            Não fiz
          </FilterPill>
        </div>

        <div className="flex flex-wrap items-center gap-1">
          <span className="mr-1 text-xs text-muted">feitas por</span>
          <FilterPill active={doneBy === null} onClick={() => setDoneBy(null)}>
            Qualquer um
          </FilterPill>
          {members.map((m) => (
            <FilterPill key={m.id} active={doneBy === m.id} onClick={() => setDoneBy(m.id)}>
              {m.name}
            </FilterPill>
          ))}
        </div>

        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Buscar pelo nome…"
          autoComplete="off"
          className="w-full rounded-md border border-border bg-surface px-3 py-1.5 text-sm
            outline-none focus:border-accent sm:ml-auto sm:w-64"
        />
      </div>

      {error && <ErrorBanner message={error} onClose={() => setError(null)} />}

      {items.length === 0 ? (
        <p className="text-sm text-muted">
          {loading
            ? 'carregando…'
            : filtering
              ? 'Nenhuma task concluída com esse filtro.'
              : 'O grupo ainda não concluiu nenhuma task. Elas aparecem aqui conforme forem saindo.'}
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

                <RowActions
                  entry={entry}
                  hasActiveExtra={hasActiveExtra}
                  busy={busy}
                  onComplete={() => setConfirming({ entry, action: 'complete' })}
                  onTakeExtra={() => setConfirming({ entry, action: 'take' })}
                />
              </li>
            )
          })}
        </ul>
      )}

      {items.length > 0 && nextOffset < matchTotal && (
        <Button variant="ghost" loading={loading} onClick={() => void loadPage(nextOffset)}>
          Carregar mais
        </Button>
      )}

      <ConfirmDialog
        open={confirming !== null}
        title={confirming?.action === 'take' ? 'Pegar como task extra?' : 'Registrar como feita?'}
        message={
          confirming?.action === 'take'
            ? `“${confirming.entry.name}” entra no seu board ao lado da sua task normal, e não dá para devolver: concluir é a única saída, e você só pode ter uma extra por vez. Ela não mexe no progresso do grupo — ao concluir, você entra no contador dessa task.`
            : `“${confirming?.entry.name ?? ''}” entra no contador dessa task em seu nome, agora. Não mexe no progresso do grupo e não tem como desfazer.`
        }
        confirmLabel={confirming?.action === 'take' ? 'Pegar extra' : 'Registrar'}
        busy={busy}
        onConfirm={() => {
          if (!confirming) return
          void (confirming.action === 'take'
            ? takeExtra(confirming.entry)
            : complete(confirming.entry))
        }}
        onCancel={() => setConfirming(null)}
      />
    </main>
  )
}

/**
 * As duas acoes da linha. Cada motivo de bloqueio tem o seu texto — a RPC
 * recusaria de qualquer jeito, mas dizer o porque antes do clique e melhor do
 * que devolver um erro depois.
 */
/*
 * O caso "todo mundo do grupo ja fez" nao aparece aqui de proposito: se
 * `completed_count` bateu o total de membros, eu sou um deles, entao
 * `done_by_me` ja cobre.
 */
function RowActions({
  entry,
  hasActiveExtra,
  busy,
  onComplete,
  onTakeExtra,
}: {
  entry: CompletedEntry
  hasActiveExtra: boolean
  busy: boolean
  onComplete: () => void
  onTakeExtra: () => void
}) {
  // Ja fiz esta task: nao ha mais nada a fazer nela.
  if (entry.done_by_me) {
    return (
      <span className="shrink-0 text-xs text-muted" title="Você já fez essa task">
        feita
      </span>
    )
  }

  // Ja esta no meu board: so falta concluir. `complete_extra_by_id` fecha
  // justamente a extra ativa quando ela e desta task.
  if (entry.extra_active) {
    return (
      <>
        <span
          className="shrink-0 text-xs font-semibold text-accent"
          title="Está no seu board agora"
        >
          sua extra
        </span>
        <Button variant="ghost" className="shrink-0" disabled={busy} onClick={onComplete}>
          Concluir
        </Button>
      </>
    )
  }

  return (
    <>
      {/* Registrar direto nao passa pelo estado "extra ativa", entao
          `hasActiveExtra` nao bloqueia este botao — e o ponto da mudanca. */}
      <Button
        variant="ghost"
        className="shrink-0"
        disabled={busy}
        title="Marcar que você já fez essa task, sem pegar de extra"
        onClick={onComplete}
      >
        Completar
      </Button>

      <Button
        variant="ghost"
        className="shrink-0"
        disabled={hasActiveExtra || busy}
        title={
          hasActiveExtra
            ? 'Você já tem uma task extra. Conclua ou devolva ela primeiro.'
            : 'Colocar no seu board para fazer depois — sem devolver'
        }
        onClick={onTakeExtra}
      >
        Pegar extra
      </Button>
    </>
  )
}
