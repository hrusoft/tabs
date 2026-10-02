/**
 * The browser package's URL scheme policy, which is now *two* policies for two
 * genuinely different questions — kept in one file because they read as one
 * subject, but each unforked across its own enforcement points.
 *
 * ## `isAllowedUrl` — steer-to
 *
 * What an agent may *navigate a pane to*. Two enforcement points that must not
 * fork: the navigating verbs check it up front (browserExternalControl.ts's
 * verb table), and the will-navigate guard on agent-owned guests (main/index.ts's
 * did-attach-webview handler) re-checks it for navigations the *page* initiates
 * — `executeJavaScript` setting `location.href`, a link click — which would
 * otherwise walk straight around the verb-level check (e.g. to `file://`,
 * turning get-page-text into a local file reader). Navigation is a load into
 * the visible pane, so it is deliberately narrow: `http`/`https`/`about:blank`.
 *
 * ## `isAllowedResourceUrl` — read-from
 *
 * What `save-resource` may *fetch bytes from*. A resource fetch is a read in
 * the page's own context, not a navigation, so it is a different question with
 * a different answer: `blob:` and `data:` are page-minted content and the whole
 * point of the verb (the reported incident was a `blob:` PDF), so they are
 * allowed here though they are meaningless as navigation targets. `file:` stays
 * refused — this is the load-bearing overlap, since save-resource's http(s)
 * route is a main-process `net.request` that could read a local file if asked,
 * so the refusal is checked against *both* the caller's `--url` and the URL
 * resolved from an element's `src` (a hostile attribute could hold `file:`).
 * Everything not on the list is refused.
 *
 * Both live beside their callers rather than in core's externalControl.ts, where
 * the first started: these are policies about what an *embedded page* may be
 * steered to or read from, which is this content type's question, and core never
 * asked either. Core keeps the URL policy that is genuinely its own —
 * openExternal.ts's, about what may be handed to the OS browser.
 */
export function isAllowedUrl(raw: string): boolean {
  if (raw === 'about:blank') return true
  try {
    const { protocol } = new URL(raw)
    return protocol === 'http:' || protocol === 'https:'
  } catch {
    return false
  }
}

/** The read-from twin of `isAllowedUrl` — see this file's header for why it differs. */
export function isAllowedResourceUrl(raw: string): boolean {
  try {
    const { protocol } = new URL(raw)
    return (
      protocol === 'http:' || protocol === 'https:' || protocol === 'blob:' || protocol === 'data:'
    )
  } catch {
    return false
  }
}
