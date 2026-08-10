import { useState } from 'react'

/**
 * As imagens vem do wiki do OSRS por hotlink. Se o wiki bloquear ou o item nao
 * tiver imagem, cai num placeholder em vez de deixar um icone quebrado na tela.
 */
export function TaskImage({
  src,
  alt,
  className = '',
}: {
  src: string
  alt: string
  className?: string
}) {
  const [broken, setBroken] = useState(false)

  if (broken) {
    return (
      <div
        className={`flex items-center justify-center rounded bg-surface-2 text-muted ${className}`}
        aria-hidden
      >
        <span className="text-lg">?</span>
      </div>
    )
  }

  return (
    <img
      src={src}
      alt={alt}
      loading="lazy"
      referrerPolicy="no-referrer"
      onError={() => setBroken(true)}
      className={`object-contain ${className}`}
    />
  )
}
