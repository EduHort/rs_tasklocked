import { useCallback, useEffect, useRef, useState } from 'react'
import { getState, isAuthError } from '../lib/api.ts'
import type { GroupState } from '../lib/types.ts'

const POLL_MS = 3000

type Result = {
  state: GroupState | null
  loading: boolean
  error: string | null
  /** Rebusca agora. Chame logo apos gerar/concluir para nao esperar o poll. */
  refresh: () => Promise<void>
}

/**
 * Mantem o board sincronizado com o grupo.
 *
 * Usa polling em vez de Realtime porque as tabelas tem RLS sem policy (todo
 * acesso passa por RPC), e o Postgres Changes do Supabase respeita RLS — nao
 * entregaria nada. Para 5 pessoas, 3s e mais que suficiente.
 */
export function useGroupState(token: string | null, onAuthError: () => void): Result {
  const [state, setState] = useState<GroupState | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  // refs para o timer nao reiniciar a cada render
  const onAuthErrorRef = useRef(onAuthError)
  onAuthErrorRef.current = onAuthError

  const refresh = useCallback(async () => {
    if (!token) return
    try {
      setState(await getState(token))
      setError(null)
    } catch (err) {
      if (isAuthError(err)) {
        onAuthErrorRef.current()
        return
      }
      setError(err instanceof Error ? err.message : 'Falha ao carregar o grupo.')
    } finally {
      setLoading(false)
    }
  }, [token])

  useEffect(() => {
    if (!token) return
    let alive = true

    const tick = () => {
      // nao gasta requisicao com a aba em segundo plano
      if (document.visibilityState === 'visible' && alive) void refresh()
    }

    void refresh()
    const id = setInterval(tick, POLL_MS)
    document.addEventListener('visibilitychange', tick)
    window.addEventListener('focus', tick)

    return () => {
      alive = false
      clearInterval(id)
      document.removeEventListener('visibilitychange', tick)
      window.removeEventListener('focus', tick)
    }
  }, [token, refresh])

  return { state, loading, error, refresh }
}
