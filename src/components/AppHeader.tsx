import { NavLink } from 'react-router-dom'

const linkClass = ({ isActive }: { isActive: boolean }) =>
  `rounded-md px-3 py-1.5 text-sm font-semibold transition ${
    isActive ? 'bg-surface-2 text-accent' : 'text-muted hover:text-ink'
  }`

export function AppHeader({ name, onLogout }: { name: string; onLogout: () => void }) {
  return (
    <header className="border-b border-border bg-surface/60">
      <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-x-4 gap-y-2 px-5 py-3">
        <span className="font-bold tracking-tight">Task Locked</span>

        <nav className="flex items-center gap-1">
          <NavLink to="/board" className={linkClass}>
            Tasks
          </NavLink>
          <NavLink to="/completed" className={linkClass}>
            Concluídas
          </NavLink>
          <NavLink to="/pending" className={linkClass}>
            A fazer
          </NavLink>
        </nav>

        <div className="ml-auto flex items-center gap-3 text-sm text-muted">
          <span className="hidden sm:inline">{name}</span>
          <button type="button" onClick={onLogout} className="hover:text-ink">
            sair
          </button>
        </div>
      </div>
    </header>
  )
}
