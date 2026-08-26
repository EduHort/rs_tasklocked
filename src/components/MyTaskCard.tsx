import { useState } from 'react'
import { timeAgo } from '../lib/format.ts'
import type { ActiveAssignment, Tier } from '../lib/types.ts'
import { Button } from './Button.tsx'
import { ConfirmDialog } from './ConfirmDialog.tsx'
import { TaskImage } from './TaskImage.tsx'
import { TierBadge } from './TierBadge.tsx'

/**
 * O UNICO lugar do app com os botoes de gerar e concluir. Eles agem sempre
 * sobre quem esta logado — as RPCs nem aceitam um member_id de terceiro.
 */
export function MyTaskCard({
  name,
  active,
  currentTier,
  busy,
  onRoll,
  onComplete,
}: {
  name: string
  active: ActiveAssignment | null
  currentTier: Tier | null
  busy: boolean
  onRoll: () => void
  onComplete: () => void
}) {
  const [confirming, setConfirming] = useState(false)

  return (
    <section className="rounded-xl border border-accent/40 bg-surface p-5">
      <header className="mb-4 flex items-center justify-between gap-3">
        <h2 className="text-sm font-bold uppercase tracking-widest text-accent">Sua task</h2>
        <span className="text-sm text-muted">{name}</span>
      </header>

      {active ? (
        <div className="flex flex-col gap-4 sm:flex-row">
          <TaskImage
            src={active.task.image_link}
            alt=""
            className="size-24 shrink-0 self-start rounded bg-surface-2 p-2"
          />

          <div className="min-w-0 flex-1">
            <TierBadge tier={active.task.tier} />
            <h3 className="mt-2 text-xl font-bold text-ink">{active.task.name}</h3>
            <p className="mt-2 text-sm leading-relaxed text-muted">{active.task.tip}</p>

            <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted">
              <a
                href={active.task.wiki_link}
                target="_blank"
                rel="noreferrer noopener"
                className="text-accent underline underline-offset-2 hover:brightness-110"
              >
                abrir no wiki
              </a>
              <span>pegou {timeAgo(active.assigned_at)}</span>
            </div>
          </div>

          <div className="shrink-0 self-start">
            <Button onClick={() => setConfirming(true)} loading={busy}>
              Concluir task
            </Button>
          </div>

          <ConfirmDialog
            open={confirming}
            title="Concluir a task?"
            message={`“${active.task.name}” sai do pool do grupo para sempre. Só dá para desfazer nos 10 minutos seguintes.`}
            confirmLabel="Concluir"
            busy={busy}
            onConfirm={() => {
              setConfirming(false)
              onComplete()
            }}
            onCancel={() => setConfirming(false)}
          />
        </div>
      ) : (
        <div className="flex flex-col items-start gap-4 py-2 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-sm text-muted">
            {currentTier ? (
              <>
                Você não tem task ativa. Gere a sua para começar.
              </>
            ) : (
              <>O grupo concluiu todas as tasks. Acabou.</>
            )}
          </p>
          <Button onClick={onRoll} loading={busy} disabled={!currentTier}>
            Gerar task
          </Button>
        </div>
      )}
    </section>
  )
}
