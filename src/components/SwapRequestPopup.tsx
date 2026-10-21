import type { Task } from '../lib/types.ts'
import { Button } from './Button.tsx'
import { TaskImage } from './TaskImage.tsx'
import { TierBadge } from './TierBadge.tsx'

/**
 * Pedido de troca RECEBIDO. Fica no canto do board ate a pessoa responder —
 * ou ate o pedido morrer porque uma das duas tasks foi concluida, e entao o
 * get_state para de manda-lo e o popup some sozinho.
 *
 * Aceitar ja e a confirmacao: as duas tasks estao escritas aqui, e nao ha
 * dialogo extra.
 */
export function SwapRequestPopup({
  fromName,
  theirTask,
  myTask,
  busy,
  onAccept,
  onDecline,
}: {
  fromName: string
  /** a task que voce recebe se aceitar */
  theirTask: Task
  /** a sua, que vai para quem pediu */
  myTask: Task
  busy: boolean
  onAccept: () => void
  onDecline: () => void
}) {
  return (
    <div
      role="status"
      className="pointer-events-auto rounded-xl border border-accent/40 bg-surface p-4 shadow-xl"
    >
      <p className="text-sm font-bold text-ink">
        <span className="text-accent">{fromName}</span> quer trocar de task com você
      </p>

      <div className="mt-3 flex items-center gap-3">
        <TaskImage src={theirTask.image_link} alt="" className="size-10 shrink-0" />
        <div className="min-w-0">
          <p className="text-xs text-muted">você recebe</p>
          <div className="flex items-center gap-2">
            <span className="truncate text-sm font-semibold text-ink" title={theirTask.name}>
              {theirTask.name}
            </span>
            <TierBadge tier={theirTask.tier} />
          </div>
        </div>
      </div>

      <p className="mt-2 truncate text-xs text-muted" title={myTask.name}>
        e {fromName} fica com a sua: <span className="text-ink">{myTask.name}</span>
      </p>

      <div className="mt-4 flex justify-end gap-2">
        <Button variant="ghost" disabled={busy} onClick={onDecline}>
          Recusar
        </Button>
        <Button disabled={busy} onClick={onAccept}>
          Aceitar
        </Button>
      </div>
    </div>
  )
}
