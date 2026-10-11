import { useCallback, useRef, useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { Button } from '../components/Button.tsx'
import { ConfirmDialog } from '../components/ConfirmDialog.tsx'
import { ErrorBanner } from '../components/ErrorBanner.tsx'
import { joinGroup } from '../lib/api.ts'
import { saveSession } from '../lib/session.ts'
import type { Session } from '../lib/types.ts'

/**
 * Login pelo codigo do grupo + nome. O nome e a conta: digitar diferente
 * ("y G" em vez de "yG") cria outra pessoa. Por isso o primeiro envio nunca
 * cria conta — se o nome e novo, a tela pergunta antes, mostrando quem ja esta
 * no grupo, e so o "Criar conta" cria de fato.
 */
export function LoginPage({ onLogin }: { onLogin: (session: Session) => void }) {
  const [code, setCode] = useState('')
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  /** nome novo esperando confirmacao: quem ja esta no grupo */
  const [newMember, setNewMember] = useState<{ members: string[] } | null>(null)
  const nameInput = useRef<HTMLInputElement>(null)
  const navigate = useNavigate()

  async function join(create: boolean) {
    setBusy(true)
    setError(null)
    try {
      const result = await joinGroup(code.trim(), name.trim(), { create })
      if (result.status === 'new') {
        setNewMember({ members: result.members })
        return
      }
      saveSession(result.session)
      onLogin(result.session)
      navigate('/board')
    } catch (err) {
      setNewMember(null)
      setError(err instanceof Error ? err.message : 'Não foi possível entrar.')
    } finally {
      setBusy(false)
    }
  }

  function handleSubmit(event: FormEvent) {
    event.preventDefault()
    void join(false)
  }

  // Cancelou: o mais provavel e que o nome esteja errado, entao volta pra ele.
  const cancelNew = useCallback(() => {
    setNewMember(null)
    nameInput.current?.focus()
    nameInput.current?.select()
  }, [])

  const others = newMember?.members ?? []

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
            ref={nameInput}
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
            maxLength={20}
            autoComplete="off"
            placeholder="ex: gugamatador"
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

      <ConfirmDialog
        open={newMember !== null}
        title="Criar uma conta nova?"
        message={
          others.length > 0
            ? `Ninguém no grupo usa o nome “${name.trim()}”. Já estão no grupo: ${others.join(', ')}. Se um desses é você, cancele e digite o nome igual — senão você entra numa conta nova, do zero.`
            : `Ninguém entrou no grupo ainda. Você vai ser a primeira pessoa, com o nome “${name.trim()}”.`
        }
        confirmLabel="Criar conta"
        busy={busy}
        onConfirm={() => void join(true)}
        onCancel={cancelNew}
      />
    </main>
  )
}
