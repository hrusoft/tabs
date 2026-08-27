import type { ElectronApplication } from 'playwright'

/** What a guest is, at the moment of asking — its identity and where it has got to. */
interface GuestSnapshot {
  id: number
  url: string
  loading: boolean
}

/**
 * Every live `<webview>` guest, in Electron's own order.
 *
 * The `getType() === 'webview'` filter is the one rule for "which WebContents
 * are guests" and lives here rather than being restated per spec — a guest is a
 * separate WebContents that never appears as a frame of the host page, so main
 * is the only place that can enumerate them at all.
 *
 * Snapshots rather than live objects because they have to cross the
 * `app.evaluate` boundary. A test that needs the object itself (to inject input
 * into it, say) has to write its own evaluate.
 */
export function guestSnapshots(app: ElectronApplication): Promise<GuestSnapshot[]> {
  return app.evaluate(({ webContents }) =>
    webContents
      .getAllWebContents()
      .filter((wc) => wc.getType() === 'webview')
      .map((wc) => ({ id: wc.id, url: wc.getURL(), loading: wc.isLoading() }))
  )
}

/**
 * Runs an expression inside the app's single `<webview>` guest page and
 * returns its result. Goes main-process → guest `webContents` rather than
 * through Playwright, for two reasons: `frameLocator` only understands
 * `<iframe>`, and a `<webview>` guest is a separate WebContents that never
 * appears as a frame of the host page; and routing around the renderer's own
 * code keeps this an independent observation rather than an echo of the code
 * path under test. Deliberately hard-fails unless exactly one guest exists —
 * a test with several browser panes needs a more precise address than this.
 * A real throw, not an error string in the value channel: a diagnostic
 * returned as data would be indistinguishable from page text at the call
 * site, and a future negative assertion could pass against it vacuously.
 */
export function guestEval<T>(app: ElectronApplication, expression: string): Promise<T> {
  return app.evaluate(async ({ webContents }, expr) => {
    const guests = webContents.getAllWebContents().filter((wc) => wc.getType() === 'webview')
    if (guests.length !== 1) {
      throw new Error(`expected exactly one guest webview, found ${guests.length}`)
    }
    return guests[0]!.executeJavaScript(expr)
    // The one cast: executeJavaScript is untyped (any), and this boundary is
    // where the caller's T takes over.
  }, expression) as Promise<T>
}

/**
 * Reads text straight out of the guest page, to check that an input
 * genuinely reached its DOM rather than that a request round-tripped.
 */
export function guestText(app: ElectronApplication, selector: string): Promise<string | null> {
  return guestEval<string | null>(
    app,
    `document.querySelector(${JSON.stringify(selector)})?.textContent ?? null`
  )
}
