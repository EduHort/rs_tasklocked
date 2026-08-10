import { timeAgo } from '../lib/format.ts'
import type { Member } from '../lib/types.ts'
import { TaskImage } from './TaskImage.tsx'
import { TierBadge } from './TierBadge.tsx'

/**
 * Card dos OUTROS membros do grupo: puramente informativo, sem nenhum botao.
 * Gerar e concluir sao acoes individuais e ficam so no seu proprio card
 * (ver MyTaskCard).
 */
export function MemberCard({ member }: { member: Member }) {
  const task = member.active?.task

  return (
    <div className="flex gap-3 rounded-lg border border-border bg-surface p-3">
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
      </div>
    </div>
  )
}
