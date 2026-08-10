import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Button } from '../components/Button.tsx'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { joinGroup } from '../lib/api.ts'
import { saveSession } from '../lib/session.ts'
import type { Session } from '../lib/types.ts'

export function LoginPage({ onLogin }: { onLogin: (session: Session) => void }) {
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const navigate = useNavigate()

  async function handleSubmit(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const session = await joinGroup(code.trim(), name.trim())
      saveSession(session)
      onLogin(session)
      navigate('/board')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível entrar.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="mx-auto flex min-h-full max-w-md flex-col justify-center gap-6 px-5 py-12">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Task Locked</h1>
        <p className="mt-1 text-sm text-muted">
          Randomizador de tasks de OSRS para o grupo. Entre com o código e escolha seu nome.
        </p>
      </div>

      <form onSubmit={handleSubmit} className="flex flex-col gap-4">
        <label className="flex flex-col gap-1.5">
          <span className="text-xs font-semibold uppercase tracking-widest text-muted">
            Código do grupo
          </span>
          <input
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase())}
            required
            autoFocus
            autoComplete="off"
            spellCheck={false}
            placeholder="ex: ABC123"
            className="rounded-md border border-border bg-surface px-3 py-2 font-mono
              tracking-[0.3em] uppercase outline-none focus:border-accent"
          />
        </label>

        <label className="flex flex-col gap-1.5">
          <span className="text-xs font-semibold uppercase tracking-widest text-muted">
            Seu nome no grupo
          </span>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
            maxLength={20}
            autoComplete="off"
            placeholder="ex: gugumatador"
            className="rounded-md border border-border bg-surface px-3 py-2 outline-none
              focus:border-accent"
          />
          <span className="text-xs text-muted">
            Se você já entrou antes com esse nome, volta pra mesma sessão.
          </span>
        </label>

        {error && <ErrorBanner message={error} onClose={() => setError(null)} />}

        <Button type="submit" loading={busy} className="mt-1 w-full">
          Entrar
        </Button>
      </form>
    </main>
  )
}
