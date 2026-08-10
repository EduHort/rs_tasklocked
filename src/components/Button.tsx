import type { ButtonHTMLAttributes } from 'react'

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'primary' | 'ghost' | 'danger'
  loading?: boolean
}

const VARIANTS = {
  primary: 'bg-accent text-accent-ink hover:brightness-110 border-transparent',
  ghost: 'bg-surface-2 text-ink hover:bg-border border-border',
  danger: 'bg-transparent text-danger hover:bg-surface-2 border-border',
} as const

export function Button({ variant = 'primary', loading, disabled, children, ...rest }: Props) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={`inline-flex items-center justify-center gap-2 rounded-md border px-4 py-2
        text-sm font-semibold tracking-wide transition
        disabled:cursor-not-allowed disabled:opacity-45 disabled:hover:brightness-100
        ${VARIANTS[variant]} ${rest.className ?? ''}`}
    >
      {loading && (
        <span className="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent" />
      )}
      {children}
    </button>
  )
}
