import { useCallback, useState } from 'react'
import { Navigate, Route, Routes, useNavigate } from 'react-router-dom'
import { AppHeader } from './components/AppHeader.tsx'
import { clearSession, loadSession } from './lib/session.ts'
import type { Session } from './lib/types.ts'
import { BoardPage } from './pages/BoardPage.tsx'
import { CompletedPage } from './pages/CompletedPage.tsx'
import { LoginPage } from './pages/LoginPage.tsx'
import { PendingPage } from './pages/PendingPage.tsx'

export function App() {
  const [session, setSession] = useState<Session | null>(loadSession)
  const navigate = useNavigate()

  const logout = useCallback(() => {
    clearSession()
    setSession(null)
    navigate('/')
  }, [navigate])

  if (!session) {
    return (
      <Routes>
        <Route path="/" element={<LoginPage onLogin={setSession} />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    )
  }

  return (
    <div className="flex min-h-full flex-col">
      <AppHeader name={session.name} onLogout={logout} />
      <Routes>
        <Route path="/board" element={<BoardPage session={session} onAuthError={logout} />} />
        <Route
          path="/completed"
          element={<CompletedPage session={session} onAuthError={logout} />}
        />
        <Route path="/pending" element={<PendingPage session={session} onAuthError={logout} />} />
        <Route path="*" element={<Navigate to="/board" replace />} />
      </Routes>
    </div>
  )
}
