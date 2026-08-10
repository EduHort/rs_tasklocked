export function ErrorBanner({ message, onClose }: { message: string; onClose?: () => void }) {
  return (
    <div
      role="alert"
      className="flex items-start justify-between gap-3 rounded-md border border-danger/50
        bg-danger/10 px-4 py-3 text-sm text-ink"
    >
      <span>{message}</span>
      {onClose && (
        <button
          type="button"
          onClick={onClose}
          aria-label="Fechar aviso"
          className="shrink-0 text-muted hover:text-ink"
        >
          ×
        </button>
      )}
    </div>
  )
}
