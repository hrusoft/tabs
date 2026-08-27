import { REATTACH_GRACE_MS } from '../src/shared/reattach'
import { openBrowser } from './helpers/browser'
import {
  grabAndHover,
  grabAndHoverCenter,
  holdPastSpringLoad,
  releaseOnRightEdge
} from './helpers/drag'
import { requireBox } from './helpers/geometry'
import { expect, test } from './helpers/launch'
import { headerOf, initialPane, openNewTab, paneById, splitHorizontal } from './helpers/pane'
import { alive, openTerminal, typeAndEnter } from './helpers/terminal'

// Only the tests whose subject is real Electron content remain here: a shell
// surviving a structural pane move (reattach, not respawn) — once through a
// center merge, once through an edge dock — and a drag crossing a `<webview>`
// guest, which is the one thing on screen that can take the pointer away from
// the host window mid-gesture. The drag/dock mechanics themselves live in
// e2e/browser/pane-drag.spec.ts, on stub content.

test('dropping a pane at the center of a terminal pane merges the two into one tab group', async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper permanently occupies pane 0 (ensureTabsRoot in
  // tree.ts). The split activated its own new pane (nth(2)): terminal B
  // lives there; the original split child (nth(1)) gets terminal A.
  const termB = await openTerminal(panes.nth(2))
  const pidB = Number(await termB.getAttribute('data-pty-pid'))

  const termA = await openTerminal(panes.nth(1))
  const pidA = Number(await termA.getAttribute('data-pty-pid'))
  expect(pidA).not.toBe(pidB)
  const terms = page.getByTestId('terminal')
  await expect(terms).toHaveCount(2)

  const targetBox = await requireBox(panes.nth(2))
  await grabAndHover(
    headerOf(panes.nth(1)),
    targetBox.x + targetBox.width / 2,
    targetBox.y + targetBox.height / 2
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // The bare target was promoted into a two-tab group — the dragged pane's
  // terminal beside it, active — and the vacated split collapsed away. Root's
  // own tablist is untouched, so this is the second one.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  const tabs = page.getByRole('tablist').nth(1).getByRole('tab')
  await expect(tabs).toHaveCount(2)
  await expect(page.getByRole('tab', { name: 'Terminal' })).toHaveCount(2)
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(terms).toHaveCount(2)
  await expect(terms.nth(0)).toHaveAttribute('data-pty-pid', String(pidB))
  await expect(terms.nth(1)).toHaveAttribute('data-pty-pid', String(pidA))

  // Both shells reattached rather than respawned: outlive the disposal grace.
  await page.waitForTimeout(REATTACH_GRACE_MS * 2)
  expect(await alive(electronApp, pidA)).toBe(true)
  expect(await alive(electronApp, pidB)).toBe(true)
})

test('a terminal keeps its shell and scrollback across an edge-dock pane drag', async ({
  page,
  electronApp
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  // Root's own wrapper stays pane 0; the split activated its own new pane,
  // nth(2), which is where the terminal goes. The untouched sibling (the
  // drag's dock target) is the original split child, nth(1).
  const term = await openTerminal(panes.nth(2))
  const pid = Number(await term.getAttribute('data-pty-pid'))
  await typeAndEnter(term, 'echo before-pane-drag-marker')
  await expect(term).toContainText('before-pane-drag-marker')

  // Dock the terminal pane against its sibling's top edge: the horizontal
  // split becomes a vertical one with the terminal on top.
  const target = await requireBox(panes.nth(1))
  await grabAndHover(
    headerOf(panes.nth(2)),
    target.x + target.width / 2,
    target.y + target.height * 0.08
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // Root's own wrapper, plus the new vertical split's two panes.
  await expect(panes).toHaveCount(3)
  await expect(panes.nth(1).getByTestId('terminal')).toBeVisible()
  const topBox = await requireBox(panes.nth(1))
  const bottomBox = await requireBox(panes.nth(2))
  expect(topBox.y).toBeLessThan(bottomBox.y)

  // Same pid, same buffer, still alive past the disposal grace period, and
  // still a working session.
  await expect(term).toHaveAttribute('data-pty-pid', String(pid))
  await expect(term).toContainText('before-pane-drag-marker')
  await page.waitForTimeout(600)
  expect(await alive(electronApp, pid)).toBe(true)
  await typeAndEnter(term, 'echo survived-the-pane-drag')
  await expect(term).toContainText('survived-the-pane-drag')
})

// A guest is a separate WebContents: the embedder hit-tests the `<webview>`
// element and routes the raw input there, so a host gesture that crosses one
// goes deaf — no more `pointermove`, and (measured, alongside no
// `pointercancel`/`lostpointercapture`/`blur`) no `pointerup` at all. Core
// answers by flagging `<body>` for the gesture's duration and letting the
// browser package's own stylesheet neutralize its guests; these two tests are
// the halves of that, and neither can be written in a tier without a real
// guest to be swallowed by.

test('every guest goes inert while a pane drag is in flight, and comes back after', async ({
  page
}) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  await openBrowser(panes.nth(2))
  const guest = page.locator('.browser-webview')

  await expect(guest).toHaveCSS('pointer-events', 'auto')

  const target = await requireBox(panes.nth(2))
  await grabAndHover(
    headerOf(panes.nth(1)),
    target.x + target.width / 2,
    target.y + target.height / 2
  )
  // The cross-package contract: core raises the flag, the browser package's
  // co-located CSS is what reacts to it. A side-effect stylesheet import is
  // invisible to typecheck and lint, so the computed value is the assertion.
  await expect(guest).toHaveCSS('pointer-events', 'none')

  await page.mouse.up()
  await expect(guest).toHaveCSS('pointer-events', 'auto')
})

test('a pane dragged onto a browser pane previews there and drops there', async ({ page }) => {
  await splitHorizontal(initialPane(page))
  const panes = page.getByTestId('pane')
  const browser = await openBrowser(panes.nth(2))

  // Aimed well inside the guest's own area, below the pane's toolbar — the
  // region the host used to hear nothing from, so no dock zone ever previewed
  // and a browser pane could not be dropped onto at all.
  const target = await requireBox(browser.locator('.browser-webview'))
  await grabAndHover(
    headerOf(panes.nth(1)),
    target.x + target.width / 2,
    target.y + target.height / 2
  )
  await expect(page.getByTestId('dock-preview')).toBeVisible()
  await page.mouse.up()

  // The release landed: the browser pane was promoted into a two-tab group
  // holding the dragged pane beside it, active. Root's own tablist is the
  // first, so this is the second.
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(page.getByRole('tablist').nth(1).getByRole('tab')).toHaveCount(2)
  await expect(page.locator('webview')).toHaveCount(1)

  // The controller is still usable. A release the host never sees leaves the
  // session armed for the life of the window — `armSession` refuses every
  // later drag, and the next click's pointerup lands as a drop of the stale
  // subject wherever the pointer happens to be.
  await grabAndHover(headerOf(panes.nth(1)), 40, 400)
  await expect(page.locator('.drag-ghost')).toBeVisible()
  await page.mouse.up()
})

// A `<webview>`'s `focus()` is Electron's override, not the element's: it
// forwards into the guest `WebContents`, so it throws when there isn't one.
// A structural move destroys the guest and rebuilds it under the same element
// (browserRegistry.ts) while React remounts the pane in the same commit, so
// core's focus-follows-active asks a guestless element for focus — and that
// throw, escaping a layout effect, unmounted the whole app. Only reproducible
// with a real guest, hence this tier; the tree mechanics of the same gesture
// are in e2e/browser/pane-drag.spec.ts on stub content.
test('a browser pane dragged out of a nested group onto an ancestor bar survives the guest gap', async ({
  page
}) => {
  const crashes: string[] = []
  page.on('pageerror', (error) => crashes.push(error.message))

  // Two top-level tabs, a browser pane each. New Tab clones the origin's own
  // type, so the second arrives as a browser too.
  await openBrowser(initialPane(page))
  await openNewTab(initialPane(page))
  const panes = page.getByTestId('pane')
  const rootTabs = page.getByRole('tablist').first().getByRole('tab')
  await expect(rootTabs).toHaveCount(2)
  await expect(page.locator('webview')).toHaveCount(2)

  // Drag tab 2 onto tab 1, let it spring open, and dock into the revealed
  // pane's right edge: the tab lands as a single-tab GROUP, so its browser
  // pane is now that group's child, one level below root's own bar.
  const paneA = paneById(page, await panes.nth(1).getAttribute('data-dock-id'))
  await grabAndHoverCenter(rootTabs.nth(1), rootTabs.nth(0))
  await holdPastSpringLoad(page)
  await releaseOnRightEdge(paneA)
  await expect(rootTabs).toHaveCount(1)
  await expect(page.getByRole('tablist')).toHaveCount(2)

  // Now drag that child back out, onto root's bar — the move that walks the
  // guest through destroy-and-rebuild.
  const childId = await panes.last().getAttribute('data-dock-id')
  const rootTab = await requireBox(rootTabs.first())
  await grabAndHover(
    headerOf(paneById(page, childId)),
    rootTab.x + rootTab.width * 0.75,
    rootTab.y + rootTab.height / 2
  )
  await holdPastSpringLoad(page)
  await page.mouse.up()

  // The app is still mounted — this is the assertion the old code failed, by
  // tearing the tree down and leaving an empty <body> behind.
  await expect(rootTabs).toHaveCount(2)
  await expect(page.getByRole('tablist')).toHaveCount(1)
  await expect(page.locator('webview')).toHaveCount(2)
  expect(crashes).toEqual([])

  // And the pane it moved actually holds the keyboard: the focus that could
  // not land during the guest gap is delivered when the guest attaches, not
  // dropped (see focusGuest in BrowserRenderer.tsx).
  await expect
    .poll(() =>
      page.evaluate(
        () => document.activeElement?.closest('[data-dock-id]')?.getAttribute('data-dock-id') ?? ''
      )
    )
    .toBe(childId)
})
