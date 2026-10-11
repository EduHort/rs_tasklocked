/** "há 3 min", "há 2 h", "há 4 d" */
export function timeAgo(iso: string): string {
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000)
  if (seconds < 60) return 'agora'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `há ${minutes} min`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `há ${hours} h`
  return `há ${Math.floor(hours / 24)} d`
}

/** "27 d 13 h", "4 h 12 min", "8 min", "35 s" — as duas maiores unidades. */
export function formatDuration(secs: number): string {
  const s = Math.round(secs)
  if (s < 60) return `${s} s`
  const minutes = Math.floor(s / 60)
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return minutes % 60 ? `${hours} h ${minutes % 60} min` : `${hours} h`
  const days = Math.floor(hours / 24)
  return hours % 24 ? `${days} d ${hours % 24} h` : `${days} d`
}

/**
 * "23/09" a partir de uma data pura ("2026-09-23"). Sem passar por `Date`: ele
 * leria como meia-noite UTC, e no Brasil isso ainda e o dia anterior.
 */
export function formatDay(day: string): string {
  const [, month, date] = day.split('-')
  return `${date}/${month}`
}

/** "23/09" a partir de um instante, no fuso de quem esta olhando. */
export function formatShortDate(iso: string): string {
  return new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' })
}

export function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}
