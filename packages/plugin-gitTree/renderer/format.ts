/** A hash as it reads in conversation — the first seven characters, everywhere this package abbreviates one. */
export function shortHash(hash: string): string {
  return hash.slice(0, 7)
}

/** Author dates as `2026-08-05 14:32` in local time — sortable at a glance, and no relative-time ticking to keep alive. Anything that isn't a date (the working-tree row's empty one) passes through as-is. */
export function formatDate(iso: string): string {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return iso
  const pad = (value: number) => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}
