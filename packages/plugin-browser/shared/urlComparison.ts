/**
 * The rule behind the navigation verbs' `redirected` flag: is the URL a
 * navigation settled on a *different place* than the one requested, or just a
 * cosmetically normalized form of it?
 *
 * `navigate` and `createBrowserPane` report `redirected: true` when this
 * returns false, so a caller never has to string-compare heuristically. The
 * flag exists to say "you did not get the page you asked for" — so anything
 * that still delivers the requested page counts as trivial:
 *
 * - a trailing slash added or dropped (`/foo/` vs `/foo`, `""` vs `/`)
 * - query parameters *added* (a tracking param, a session id) — but a
 *   parameter the caller asked for being dropped or changed is a real
 *   difference, since auth flows routinely stash the deep link there
 * - the scheme (an http→https upgrade delivers the page asked for)
 * - the fragment (same document either way)
 *
 * A different host, port, or path is never trivial. URLs that don't parse
 * are compared as plain strings.
 *
 * Pure and process-agnostic on purpose: the renderer computes the flag per
 * verb, and the unit tier pins the rule without an Electron in sight.
 */
export function isTrivialUrlChange(requested: string, final: string): boolean {
  if (requested === final) return true
  let from: URL
  let to: URL
  try {
    from = new URL(requested)
    to = new URL(final)
  } catch {
    // Unparseable and not string-equal: report the difference rather than
    // guessing at its shape.
    return false
  }
  // `URL` lowercases hostnames and drops a scheme's default port, so http→https
  // with default ports compares equal here — which is the point. An explicit
  // port survives parsing and must match.
  if (from.hostname !== to.hostname || from.port !== to.port) return false
  if (normalizePath(from.pathname) !== normalizePath(to.pathname)) return false
  // Every parameter the caller asked for must survive with its value; what the
  // destination *added* alongside is its own business.
  for (const [key, value] of from.searchParams) {
    if (!to.searchParams.getAll(key).includes(value)) return false
  }
  return true
}

/** `/foo/` and `/foo` name the same place; the root's lone slash stays. */
function normalizePath(pathname: string): string {
  return pathname.length > 1 && pathname.endsWith('/') ? pathname.slice(0, -1) : pathname
}
