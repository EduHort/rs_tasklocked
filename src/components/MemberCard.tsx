import { timeAgo } from '../lib/format.ts'
import type { Member } from '../lib/types.ts'
import { Button } from './Button.tsx'
import { TaskImage } from './TaskImage.tsx'
import { TierBadge } from './TierBadge.tsx'

/**
 * Card dos OUTROS membros do grupo. Gerar e concluir sao acoes individuais e
 * ficam so no seu proprio card (ver MyTaskCard); o unico botao aqui e o de
 * PEDIR para trocar a sua task pela desta pessoa — a troca so acontece quando
 * ela aceitar. Ele so aparece quando os dois estao com task ativa.
 *
 * `swap`: 'sent' = voce pediu e ela ainda nao respondeu · 'received' = ela
 * pediu a voce (a resposta fica no popup do board) · null = nenhum pedido.
 */
export function MemberCard({
  member,
  hasTask,
  canSwap,
  swap,
  busy,
  onRequestSwap,
  onCancelSwap,
}: {
  member: Member
  /** voce tem task ativa — sem ela nao ha o que trocar, e o botao nem aparece */
  hasTask: boolean
  /** false = voce ja tem um pedido enviado para outra pessoa */
  canSwap: boolean
  swap: 'sent' | 'received' | null
  busy: boolean
  onRequestSwap: () => void
  onCancelSwap: () => void
}) {
  const task = member.active?.task

  return (
    <div
      className={`flex gap-3 rounded-lg border bg-surface p-3 ${
        swap ? 'border-accent/40' : 'border-border'
      }`}
    >
      {task ? (
        <TaskImage src={task.image_link} alt="" className="size-12 shrink-0" />
      ) : (
        <div className="size-12 shrink-0 rounded bg-surface-2" />
      )}

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="truncate font-semibold">{member.name}</span>
          {task && <TierBadge tier={task.tier} />}
        </div>

        {task ? (
          <>
            <p className="mt-0.5 truncate text-sm text-ink" title={task.name}>
              {task.name}
            </p>
            <p className="text-xs text-muted">pegou {timeAgo(member.active!.assigned_at)}</p>
          </>
        ) : (
          <p className="mt-1 text-sm text-muted">sem task no momento</p>
        )}

        {member.extra && (
          <p className="mt-1 truncate text-xs text-muted" title={member.extra.task.name}>
            <span className="text-accent">+ extra</span> {member.extra.task.name}
          </p>
        )}
      </div>

      {swap === 'sent' ? (
        <div className="flex shrink-0 flex-col items-end gap-1 self-start">
          <span className="text-xs text-accent">troca pedida</span>
          <Button
            variant="ghost"
            disabled={busy}
            onClick={onCancelSwap}
            className="px-2.5 py-1 text-xs"
          >
            Cancelar
          </Button>
        </div>
      ) : swap === 'received' ? (
        <span className="shrink-0 self-start text-xs font-semibold text-accent">
          quer trocar com você
        </span>
      ) : (
        task &&
        hasTask && (
          <Button
            variant="ghost"
            disabled={busy || !canSwap}
            onClick={onRequestSwap}
            title={
              canSwap
                ? `Pedir para trocar a sua task pela de ${member.name}`
                : 'Você já tem um pedido de troca esperando resposta. Cancele ele para pedir outro.'
            }
            className="shrink-0 self-start px-2.5 py-1 text-xs"
          >
            Trocar
          </Button>
        )
      )}
    </div>
  )
}
