import type { ElectronApplication, Locator, Page } from 'playwright'
import { grabAndHover } from './drag'
import { centerOf, requireBox } from './geometry'
import { expect } from './launch'
import { clickMenuItem } from './menu'

/**
 * Opens another pane-tree window through the menu (not a singleton — call
 * again for a third) and returns its Page. Not `app.waitForEvent('window')`:
 * with a `<webview>` guest active anywhere, the Page it resolves to can sit
 * on its pre-navigation `about:blank` well past any reasonable wait
 * (measured at roughly two failures in three). Polling `app.windows()` for
 * a new page already on `index.html` sidesteps discovery order.
 */
export async function openNewPaneTreeWindow(app: ElectronApplication, page: Page): Promise<Page> {
  const before = new Set(app.windows())
  await clickMenuItem(app, 'New Window', page)
  await expect
    .poll(
      () =>
        app
          .windows()
          .some((candidate) => !before.has(candidate) && candidate.url().includes('index.html')),
      { timeout: 30_000 }
    )
    .toBe(true)
  const newPage = app
    .windows()
    .find((candidate) => !before.has(candidate) && candidate.url().includes('index.html'))
  if (!newPage) throw new Error('New Window did not produce a loaded pane-tree window')
  await newPage.getByTestId('pane').first().waitFor()
  return newPage
}

/** The window's content bounds in screen coordinates — the space `screen.getCursorScreenPoint()` reports in — matched by its unique URL. */
export async function windowContentBounds(
  app: ElectronApplication,
  page: Page
): Promise<{ x: number; y: number; width: number; height: number }> {
  const targetUrl = page.url()
  const bounds = await app.evaluate(({ BrowserWindow }, url) => {
    const win = BrowserWindow.getAllWindows().find(
      (candidate) => candidate.webContents.getURL() === url
    )
    return win ? win.getContentBounds() : null
  }, targetUrl)
  if (!bounds) throw new Error(`No BrowserWindow found for ${targetUrl}`)
  return bounds
}

/**
 * Lays two pane-tree windows out on the left and right halves of the primary
 * display, so no point is inside both. A new window cascades only slightly
 * off its opener, and a point inside the source's bounds always belongs to
 * the source (see pollHover in src/main/layoutCrossWindow.ts), so a test
 * that wants a hover to land in the other window has to do this first.
 */
export async function placeWindowsSideBySide(
  app: ElectronApplication,
  left: Page,
  right: Page
): Promise<void> {
  const contentBounds = await app.evaluate(
    ({ BrowserWindow, screen }, urls) => {
      const { workArea } = screen.getPrimaryDisplay()
      const half = Math.floor(workArea.width / 2)
      const bounds = [
        { x: workArea.x, y: workArea.y, width: half - 10, height: workArea.height },
        { x: workArea.x + half + 10, y: workArea.y, width: half - 10, height: workArea.height }
      ]
      return urls.map((url, index) => {
        const win = BrowserWindow.getAllWindows().find(
          (candidate) => candidate.webContents.getURL() === url
        )
        if (!win) throw new Error(`No BrowserWindow found for ${url}`)
        win.setBounds(bounds[index]!)
        return win.getContentBounds()
      })
    },
    [left.url(), right.url()]
  )
  // Wait for each viewport to follow the resize before anything measures.
  for (const [index, page] of [left, right].entries()) {
    const expected = contentBounds[index]!
    await expect
      .poll(() => page.evaluate(() => [window.innerWidth, window.innerHeight]))
      .toEqual([expected.width, expected.height])
  }
}

type Box = { x: number; y: number; width: number; height: number }

/**
 * Engages a drag on `grab` and hovers `target` in `other` through main's
 * cursor poll, resolving once `other` shows the preview (a dock preview, or
 * an empty pane's drop highlight, unless `preview` says otherwise). The caller releases in the *source*
 * window, where a real release is delivered. The local pointer parks in the
 * dragged subject's own body, which is never a target. `pointIn` picks the
 * spot inside `target`; the default is its center.
 */
export async function hoverIntoWindow(
  app: ElectronApplication,
  grab: Locator,
  other: Page,
  target: Locator,
  options: {
    pointIn?: (box: Box) => { x: number; y: number }
    preview?: (page: Page) => Locator
  } = {}
): Promise<void> {
  await engageCrossWindowDrag(app, grab)
  const bounds = await windowContentBounds(app, other)
  const point = (options.pointIn ?? centerOf)(await requireBox(target))
  await setCrossWindowCursorPoint(app, { x: bounds.x + point.x, y: bounds.y + point.y })
  const preview =
    options.preview ??
    ((page: Page) => page.locator('[data-testid="dock-preview"], .empty-pane-drop-target'))
  await expect(preview(other)).toBeVisible()
}

/**
 * `hoverIntoWindow`'s first half, for a test that places main's cursor
 * itself: presses `grab` and drags just off it — a real local drag, armed in
 * the source window — with main's cursor parked off every window, so nothing
 * is hovered yet.
 */
export async function engageCrossWindowDrag(
  app: ElectronApplication,
  grab: Locator
): Promise<void> {
  await setCrossWindowCursorPoint(app, OFFSCREEN_POINT)
  const grabBox = await requireBox(grab)
  await grabAndHover(grab, grabBox.x + grabBox.width / 2 + 40, grabBox.y + grabBox.height + 40)
}

/** Anywhere no pane-tree window's bounds could plausibly reach. */
export const OFFSCREEN_POINT = { x: -50_000, y: -50_000 }

/**
 * Overrides the OS cursor position main's cross-window poll reads (screen
 * coordinates; `null` stops overriding). A real drag's pointer events only
 * reach the window it began in, so cross-window detection is main polling
 * the cursor, which Playwright cannot drive — feeding the poll a point
 * exercises the real hit-test and relay rather than a faked arrival.
 *
 * Set it before engaging any drag, even to a point off every window: left
 * unset, the poll reads the machine's real pointer.
 */
export async function setCrossWindowCursorPoint(
  app: ElectronApplication,
  point: { x: number; y: number } | null
): Promise<void> {
  await app.evaluate((_electron, p) => {
    globalThis.__tabsE2e?.setCrossWindowCursorPoint(p)
  }, point)
}

/**
 * Keeps `page`'s renderer main thread busy for `ms`, without waiting for it —
 * so a relayed request sent to it meanwhile sits unanswered, the way it would
 * behind a slow or hung window. The evaluate is left to settle on its own (or
 * reject, if the renderer is crashed or reloaded under it).
 */
export function holdRendererBusy(page: Page, ms: number): void {
  page
    .evaluate((duration) => {
      const end = Date.now() + duration
      while (Date.now() < end) {
        // Deliberately spinning: nothing else may run on this thread.
      }
    }, ms)
    .catch(() => {})
}

/** Runs `action` on the BrowserWindow hosting `page`, in main — for what only main can do to a window (crash its renderer, reload it, zoom it). */
export async function onWindowOf(
  app: ElectronApplication,
  page: Page,
  action: 'crash' | 'reload'
): Promise<void> {
  await app.evaluate(
    ({ BrowserWindow }, { url, what }) => {
      const win = BrowserWindow.getAllWindows().find(
        (candidate) => candidate.webContents.getURL() === url
      )
      if (!win) throw new Error(`No BrowserWindow found for ${url}`)
      if (what === 'crash') win.webContents.forcefullyCrashRenderer()
      else win.webContents.reload()
    },
    { url: page.url(), what: action }
  )
}
