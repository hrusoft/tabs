const SCHEME_RE = /^[a-z][a-z0-9+.-]*:/i
const LOCALHOST_RE = /^localhost(:\d+)?(\/|$)/i
const DOMAIN_RE = /^[^/\s]+\.[^/\s]+/

/**
 * True when `trimmed` (no surrounding whitespace) is plausibly a bare
 * domain: `localhost` (with an optional port/path), or a dot before its
 * first slash suggesting a domain — and no internal whitespace either way,
 * since a real URL never has one.
 */
function looksLikeBareDomain(trimmed: string): boolean {
  if (/\s/.test(trimmed)) return false
  return LOCALHOST_RE.test(trimmed) || DOMAIN_RE.test(trimmed)
}

/**
 * What Enter in the address bar should navigate to — the same three-way
 * split a real browser's omnibox makes: a URL with an explicit scheme
 * passes through unchanged, something that looks like a bare domain gets
 * `https://` prepended, and everything else becomes a search-engine query.
 * Returns `null` for blank/whitespace-only input (a no-op, not a navigation
 * to an empty search).
 */
export function resolveAddressInput(raw: string): string | null {
  const trimmed = raw.trim()
  if (trimmed === '') return null
  // Checked first: "localhost:3000" would otherwise also match SCHEME_RE
  // (a bare word followed by ":" is indistinguishable from a URI scheme).
  if (looksLikeBareDomain(trimmed)) return `https://${trimmed}`
  if (SCHEME_RE.test(trimmed)) return trimmed
  return `https://www.google.com/search?q=${encodeURIComponent(trimmed)}`
}
