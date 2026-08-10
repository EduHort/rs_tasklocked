import { useEffect } from 'react'
import { Button } from './Button.tsx'

/**
 * Confirmacao para acoes que nao dao para desfazer com um clique.
 * Concluir uma task tira ela do pool do grupo PARA SEMPRE — o undo_complete so
 * cobre os 10 minutos seguintes, e so para quem concluiu.
 *
 * Fica montado apenas quando `open`, entao o autoFocus vale a cada abertura.
 * O foco vai para "Cancelar" de proposito: quem so apertou Enter sem ler nao
 * conclui a task sem querer.
 */
export function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel = 'Confirmar',
  busy = false,
  onConfirm,
  onCancel,
}: {
  open: boolean
  title: string
  message: string
  confirmLabel?: string
  busy?: boolean
  onConfirm: () => void
  onCancel: () => void
}) {
  useEffect(() => {
    if (!open) return

    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !busy) onCancel()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [open, busy, onCancel])

  if (!open) return null

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-5"
      onClick={(e) => {
        // so o clique no fundo fecha; o de dentro do card nao chega ate aqui
        if (e.target === e.currentTarget && !busy) onCancel()
      }}
    >
      <div
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="confirm-title"
        className="w-full max-w-sm rounded-xl border border-border bg-surface p-5 shadow-xl"
      >
        <h2 id="confirm-title" className="text-base font-bold text-ink">
          {title}
        </h2>
        <p className="mt-2 text-sm leading-relaxed break-words text-muted">{message}</p>

        <div className="mt-5 flex justify-end gap-2">
          <Button variant="ghost" autoFocus onClick={onCancel} disabled={busy}>
            Cancelar
          </Button>
          <Button onClick={onConfirm} loading={busy}>
            {confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  )
}
