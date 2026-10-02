import type { WebviewTag } from 'electron'
import type { ConsoleEntry, DocumentStatus } from './browserRegistry'
import { browserCtx } from './pluginContext'

/**
 * The browser-shaped view of a pane's core handle (see
 * core/registry/paneHandles.ts): what the external-control listener (see
 * browserExternalControl.ts and its verb modules) can ask of a mounted `BrowserRenderer`. Its members
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

/**
 * Narrows a generic `PaneHandle.extension` (or undefined) to this type's own
 * shape, or undefined if it isn't one — the one place that duck-type check
 * lives, shared by `getBrowserPane` (which does its own lookup by pane id)
 * and `describeForControl` (browserContentDef.ts, handed the handle directly
 * by core's `getPaneInfo`).
 */
export function narrowBrowserHandle(extension: unknown): BrowserPaneHandle | undefined {
  const candidate = extension as Partial<BrowserPaneHandle> | undefined
  return typeof candidate?.webview === 'function' ? (candidate as BrowserPaneHandle) : undefined
}

/** The mounted handle for `id`, or undefined if no `BrowserRenderer` currently holds that pane. */
export function getBrowserPane(id: string): BrowserPaneHandle | undefined {
  return narrowBrowserHandle(browserCtx.get().panes.getHandle(id)?.extension)
}
