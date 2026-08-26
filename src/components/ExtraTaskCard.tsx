import { useState } from 'react'
import { timeAgo } from '../lib/format.ts'
import type { ActiveAssignment } from '../lib/types.ts'
import { Button } from './Button.tsx'
import { ConfirmDialog } from './ConfirmDialog.tsx'
import { TaskImage } from './TaskImage.tsx'
import { TierBadge } from './TierBadge.tsx'

/**
 * A task EXTRA de quem esta logado: uma que o grupo JA concluiu e a pessoa
 * escolheu repetir, em /completed. Fica ao lado da task normal.
 *
 * Visualmente secundaria de proposito — a task do pool e que faz o grupo
 * avancar; a extra nao mexe no pool. Some quando nao ha extra ativa: quem pega
 * uma escolhe na tela de concluidas, entao nao ha botao "gerar" aqui.
 *
 * Concluir e a UNICA saida: nao ha como devolver. Como so cabe uma extra por
 * vez e ninguem repete a mesma task, pegar a errada tranca a pessoa — por isso
 * a confirmacao ao PEGAR (em /completed) e a mais enfatica das duas.
 */
export function ExtraTaskCard({
  extra,
  busy,
  onComplete,
}: {
  extra: ActiveAssignment
  busy: boolean
  onComplete: () => void
}) {
  const [confirming, setConfirming] = useState(false)

  return (
    <section className="rounded-xl border border-border bg-surface p-4">
      <header className="mb-3 flex items-center justify-between gap-3">
        <h2 className="text-sm font-bold uppercase tracking-widest text-muted">Sua task extra</h2>
        <span className="text-xs text-muted">não conta para o progresso do grupo</span>
      </header>

      <div className="flex flex-col gap-4 sm:flex-row">
        <TaskImage
          src={extra.task.image_link}
          alt=""
          className="size-16 shrink-0 self-start rounded bg-surface-2 p-2"
        />

        <div className="min-w-0 flex-1">
          <TierBadge tier={extra.task.tier} />
          <h3 className="mt-2 text-lg font-bold text-ink">{extra.task.name}</h3>
          <p className="mt-2 text-sm leading-relaxed text-muted">{extra.task.tip}</p>

          <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted">
            <a
              href={extra.task.wiki_link}
              target="_blank"
              rel="noreferrer noopener"
              className="text-accent underline underline-offset-2 hover:brightness-110"
            >
              abrir no wiki
            </a>
            <span>pegou {timeAgo(extra.assigned_at)}</span>
          </div>
        </div>

        <div className="shrink-0 self-start">
          <Button variant="ghost" loading={busy} onClick={() => setConfirming(true)}>
            Concluir extra
          </Button>
        </div>
      </div>

      <ConfirmDialog
        open={confirming}
        title="Concluir a task extra?"
        message={`Você entra no contador de “${extra.task.name}”. Não dá para desfazer, e essa task não volta a ficar disponível como extra para você.`}
        confirmLabel="Concluir"
        busy={busy}
        onConfirm={() => {
          setConfirming(false)
          onComplete()
        }}
        onCancel={() => setConfirming(false)}
      />
    </section>
  )
}
