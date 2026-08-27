import type { WebviewTag } from 'electron'
import type { ConsoleEntry, DocumentStatus } from './browserRegistry'
import { browserCtx } from './pluginContext'

/**
 * The browser-shaped view of a pane's core handle (see
 * core/registry/paneHandles.ts): what the external-control listener (see
 * ../externalControl.ts) can ask of a mounted `BrowserRenderer`. Its members
 * are getters rather than values because what they resolve to (the live
 * `<webview>` element, the current page's console buffer) is replaced
 * underneath the registered handle as the pane reattaches and renavigates.
 */
export interface BrowserPaneHandle {
  /** The live guest element, or null before it has finished attaching. */
  webview: () => WebviewTag | null
  /** Console output captured for the guest's current page, newer than `sinceSeq` if given. */
  consoleMessages: (sinceSeq?: number) => ConsoleEntry[]
  /**
   * Why the load currently in flight failed (an ERR_* description), or null.
   * Scoped to that load, not to the pane's history — it resets when the next
   * one starts. Captured by the instance's own listeners, which is what makes
   * it readable for a load that began before anyone here could listen (see
   * BrowserInstance.loadFailure).
   */
  lastLoadError: () => string | null
  /**
   * The HTTP status behind the last committed main-frame document, or null
   * for a non-HTTP one. Scoped to the committed document like `getURL()`,
   * not to the load in flight — see BrowserInstance.documentStatus.
   */
  documentStatus: () => DocumentStatus | null
}

/** The mounted handle for `id`, or undefined if no `BrowserRenderer` currently holds that pane. */
export function getBrowserPane(id: string): BrowserPaneHandle | undefined {
  const extension = browserCtx.get().panes.getHandle(id)?.extension as
    | Partial<BrowserPaneHandle>
    | undefined
  return typeof extension?.webview === 'function' ? (extension as BrowserPaneHandle) : undefined
}
