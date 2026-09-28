import type { ReactNode } from 'react'

/** Botao de um grupo de filtros — so um do grupo fica `active` por vez. */
export function FilterPill({
  active,
  onClick,
  children,
}: {
  active: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`rounded-md border px-2.5 py-1 text-xs font-semibold uppercase tracking-wider
        transition ${
          active
            ? 'border-accent bg-surface-2 text-accent'
            : 'border-border bg-surface text-muted hover:text-ink'
        }`}
    >
      {children}
    </button>
  )
}
