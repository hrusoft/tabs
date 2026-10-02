/**
 * Protocols we're willing to hand to the OS's default handler. Anything a
 * terminal pane or an embedded page can print is attacker-influenceable in
 * principle, and `shell.openExternal` will happily launch a `file:` path or a
 * registered custom scheme — so the allowlist is deliberately tiny.
 */
const EXTERNAL_PROTOCOLS = new Set(['http:', 'https:', 'mailto:'])

/** Whether `url` is safe to open outside the app, in the user's browser/mail client. */
export function isSafeExternalUrl(url: string): boolean {
  try {
    return EXTERNAL_PROTOCOLS.has(new URL(url).protocol)
  } catch {
    // Not a parseable absolute URL at all (a relative path, a bare word).
    return false
  }
}
