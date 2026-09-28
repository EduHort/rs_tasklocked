import { useEffect, useState, type FormEvent } from 'react'
import { isAuthError, renameMember } from '../lib/api.ts'
import type { Session } from '../lib/types.ts'
import { Button } from './Button.tsx'
import { ErrorBanner } from './ErrorBanner.tsx'

/**
 * Troca o nome de quem esta logado. Monte so quando for abrir: o campo nasce
 * com o nome atual a cada abertura, e um erro antigo nao reaparece.
 *
 * O nome tambem e o que a pessoa digita para entrar de novo — o aviso embaixo
 * do campo existe porque isso nao e obvio para quem so quer mudar o apelido.
 */
export function RenameDialog({
  session,
  onRenamed,
  onClose,
  onAuthError,
}: {
  session: Session
  onRenamed: (name: string) => void
  onClose: () => void
  onAuthError: () => void
}) {
  const [name, setName] = useState(session.name)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !busy) onClose()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [busy, onClose])

  const unchanged = name.trim() === session.name

  async function handleSubmit(event: FormEvent) {
    event.preventDefault()
    if (unchanged) return
    setBusy(true)
    setError(null)
    try {
      onRenamed(await renameMember(session.token, name.trim()))
    } catch (err) {
      if (isAuthError(err)) {
        onAuthError()
        return
      }
      setError(err instanceof Error ? err.message : 'Não deu para trocar o nome.')
      setBusy(false)
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-5"
      onClick={(e) => {
        // so o clique no fundo fecha; o de dentro do card nao chega ate aqui
        if (e.target === e.currentTarget && !busy) onClose()
      }}
    >
      <form
        role="dialog"
        aria-modal="true"
        aria-labelledby="rename-title"
        onSubmit={handleSubmit}
        className="w-full max-w-sm rounded-xl border border-border bg-surface p-5 shadow-xl"
      >
        <h2 id="rename-title" className="text-base font-bold text-ink">
          Trocar seu nome
        </h2>

        <label className="mt-4 flex flex-col gap-1.5">
          <span className="text-xs font-semibold uppercase tracking-widest text-muted">
            Novo nome
          </span>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            onFocus={(e) => e.target.select()}
            required
            autoFocus
            maxLength={20}
            autoComplete="off"
            className="rounded-md border border-border bg-bg px-3 py-2 text-ink outline-none
              focus:border-accent"
          />
          <span className="text-xs leading-relaxed text-muted">
            Para entrar de novo (em outro aparelho ou depois de sair), use o nome novo. O antigo
            fica livre para outra pessoa.
          </span>
        </label>

        {error && (
          <div className="mt-4">
            <ErrorBanner message={error} onClose={() => setError(null)} />
          </div>
        )}

        <div className="mt-5 flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose} disabled={busy}>
            Cancelar
          </Button>
          <Button type="submit" loading={busy} disabled={unchanged}>
            Salvar
          </Button>
        </div>
      </form>
    </div>
  )
}
