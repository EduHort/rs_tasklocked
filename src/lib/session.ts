import type { Session } from './types.ts'

const KEY = 'rs_tasklocked.session'

export function loadSession(): Session | null {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<Session>
    if (!parsed.memberId || !parsed.token || !parsed.name) return null
    return parsed as Session
  } catch {
    return null
  }
}

export function saveSession(session: Session): void {
  localStorage.setItem(KEY, JSON.stringify(session))
}

export function clearSession(): void {
  localStorage.removeItem(KEY)
}
