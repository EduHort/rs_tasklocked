import { useCallback, useState } from 'react'
import { Navigate, Route, Routes, useNavigate } from 'react-router-dom'
import { AppHeader } from './components/AppHeader.tsx'
import { RenameDialog } from './components/RenameDialog.tsx'
import { clearSession, loadSession, saveSession } from './lib/session.ts'
import type { Session } from './lib/types.ts'
import { BoardPage } from './pages/BoardPage.tsx'
import { CompletedPage } from './pages/CompletedPage.tsx'
import { LoginPage } from './pages/LoginPage.tsx'
import { PendingPage } from './pages/PendingPage.tsx'

export function App() {
  const [session, setSession] = useState<Session | null>(loadSession)
  const [renaming, setRenaming] = useState(false)
  const navigate = useNavigate()

  const logout = useCallback(() => {
    clearSession()
    setSession(null)
    setRenaming(false)
    navigate('/')
  }, [navigate])

  const closeRename = useCallback(() => setRenaming(false), [])

  // O token nao muda com o nome: so a sessao salva, para o proximo F5 ja abrir
  // com ele.
  const updateName = useCallback(
    (name: string) => {
      if (!session) return
      const next = { ...session, name }
      saveSession(next)
      setSession(next)
    },
    [session],
  )

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
      <AppHeader name={session.name} onRename={() => setRenaming(true)} onLogout={logout} />
      {renaming && (
        <RenameDialog
          session={session}
          onRenamed={(name) => {
            updateName(name)
            setRenaming(false)
          }}
          onClose={closeRename}
          onAuthError={logout}
        />
      )}
      <Routes>
        <Route
          path="/board"
          element={
            <BoardPage session={session} onAuthError={logout} onNameChange={updateName} />
          }
        />
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
