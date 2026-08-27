import type { Locator, Page } from '@playwright/test'
import { PANE_ATTR, PANE_BUTTON } from '../../src/shared/paneDomAttrs'
import { PANE_HEADER_SELECTOR } from '../../src/shared/testing/paneSelectors'
import { requireBox } from './geometry'

/**
 * The pane holding layout node `id` — the hand-built [data-dock-id=...]
 * locator, named once. Accepts null (getAttribute's shape) the way the
 * inlined templates always did: a null id matches nothing.
 */
export function paneById(page: Page, id: string | null): Locator {
  return page.locator(`[${PANE_ATTR.dock}="${id}"]`)
}

/** The docked root's own auto-wrapping tab group (see `initialPane` for the pane tests usually want). */
export function rootPane(page: Page): Locator {
  return page.getByTestId('pane').first()
}

/**
 * The pane's own chrome bar — its title bar, or, for a tab-group pane, the
 * tab strip that doubles as one. Never a nested pane's. The selector is shared
 * with the jsdom tier's own `headerOf` (src/renderer/src/testing/domQueries.ts);
 * only the Locator wrapper lives here.
 */
export function headerOf(pane: Locator): Locator {
  return pane.locator(PANE_HEADER_SELECTOR)
}

/**
 * The pane meant to be interacted with in a freshly loaded app or harness
 * page — as opposed to `page.getByTestId('pane').first()`, which is always
 * the docked root's own auto-wrapping tab group now (see `ensureTabsRoot` in
 * tree.ts). A fresh load starts with exactly that wrapper plus the one real
 * pane its lone default tab holds, in DOM order, so `.nth(1)` is the one a
 * test actually wants to split, fill, close, and so on — the same role
 * `.first()` played before the root was always a tab group. jsdom's twin is
 * `initialPane` in src/renderer/src/testing/domQueries.ts.
 */
export function initialPane(page: Page): Locator {
  return page.getByTestId('pane').nth(1)
}

/**
 * Clicks a pane to make it the active one, on a spot that holds no control.
 *
 * A bare `pane.click()` targets the box's dead centre, which for an *empty*
 * pane is exactly where its content-type toolbar now sits (see
 * EmptyPaneRenderer.tsx) — so it presses a creation button and fills the pane
 * instead of merely activating it. That is a real behaviour change and not a
 * test artifact: an empty pane's middle is a control now. What made it worth
 * a helper is that the damage is mostly *silent* — the pane does still end up
 * active (openContent hands focus to the content it just placed, in the same
 * slot), so an activation assertion keeps passing while the pane quietly
 * gains a terminal or a `<webview>`, and only a later count fails.
 *
 * Aimed just inside the bottom-left corner instead, which is padding in an
 * empty pane and inert content in every other kind. Not the header: that is a
 * drag handle, and a press there is a different path (see `chromePointerDown`).
 */
export async function activatePane(pane: Locator): Promise<void> {
  const box = await requireBox(pane)
  await pane.click({ position: { x: 12, y: box.height - 12 } })
}

/**
 * Closes the one inactive tab of root's own group — the shape left behind
 * when content opened in the initial pane (which fills root's original tab
 * in place, keeping its title — see `openContent` in tree.ts) has since been
 * backgrounded by a newly created sibling tab, which lands active. The
 * backgrounded pane's own header close button has no box to click while its
 * panel is hidden, but the tab strip's close control isn't hidden with it.
 * Selected structurally rather than by title, since both tabs can
 * legitimately read "Tabs" (`rootTabTitleForContent` names a placeholder
 * landing in root's group the same as root's own default tab). Used to tidy
 * a real shell before a spec's shared app quits — see openTerminal's note in
 * helpers/terminal.ts.
 */
export async function closeInactiveRootTab(page: Page): Promise<void> {
  await page.locator('.tab:not(.tab-active) .tab-close').click()
}

/**
 * Hovers `rootTestId`'s group to reveal its menu, then clicks `itemTestId`
 * inside it — required now that a group's non-root actions sit in a
 * `.pane-header-dropdown` that's `pointer-events: none` until its root
 * button is hovered (see global.css). Direct `.click()` on a menu item
 * without this hover first fails Playwright's actionability check.
 *
 * The hover itself needs `force: true`, and it's not a workaround for a
 * bug — it's the direct consequence of the menu opening flush *over* its
 * root button rather than below it (see `.pane-header-dropdown` in
 * global.css). Playwright's `.hover()` verifies that the *target element
 * itself* receives the pointer event at its own center — but arriving
 * there is exactly what reveals the menu that then covers it, so that
 * verification can never succeed: hovering the root makes the root stop
 * being what's actually there. A real mouse has no equivalent check — it
 * just dispatches to whatever's topmost at the cursor, which is precisely
 * what `force: true` asks Playwright to do too.
 *
 * Two further timing quirks this works around, both confirmed directly
 * (computed style + elementFromPoint mid-sequence, not guessed):
 *
 * - `:hover` flips `pointer-events` (discrete) and `opacity` (animated,
 *   `transition: opacity 0.1s`) in the same rule, but not at the same real
 *   moment — pointer-events is already `auto` the instant `:hover`
 *   matches, while opacity is still at its pre-transition value.
 *   Chromium excludes a not-yet-painted (opacity still 0) element from
 *   hit-testing, so a click right after the hover resolves falls through
 *   to whatever's underneath. A real user can't physically click faster
 *   than 100ms; only back-to-back automation can — hence the wait below.
 * - A mouse click also focuses the clicked button, and PaneHeaderMenuGroup
 *   reveals its menu on `:focus-within` too (for keyboard access) — which
 *   used to leave the menu open after a click regardless of where the
 *   mouse went next (focus doesn't move with the cursor), often
 *   overlapping whatever the click's own layout change put nearby and
 *   silently intercepting the next locator's click. Fixed at the source
 *   (HeaderButton/PaneHeaderMenuGroup blur the pressed element on click) —
 *   real users hit the same bug without a test in sight.
 *
 * That source fix does nothing for plain `:hover`, though, which a click
 * doesn't clear on its own: `.click()` leaves the cursor sitting right on
 * the item it just clicked, so the group stays genuinely hovered — no
 * staleness, no timing, just the mouse truly still being there — until
 * something moves it away. Confirmed directly: back-to-back calls (e.g.
 * two `openNewTab`s converting a pane into a tab group, then adding its
 * second tab) left the first menu `:hover`-true and `pointer-events: auto`
 * long after its own click, overlapping the very pane that click had just
 * created underneath it. Hence the move-away on both ends, not just the
 * leading one.
 */
async function openPaneMenuItem(
  pane: Locator,
  rootTestId: string,
  itemTestId: string
): Promise<void> {
  const page = pane.page()
  // (0, 0) is not a safe "away" point: it's inside the top-left pane's own
  // header (grip/root-button territory), so moving there can land right
  // back on a group instead of leaving it. y:300 is reliably below every
  // pane's ~22-26px header, in body content no group ever occupies.
  await page.mouse.move(0, 300)
  await headerOf(pane).getByTestId(rootTestId).hover({ force: true })
  await page.waitForTimeout(150)
  await headerOf(pane).getByTestId(itemTestId).click()
  await page.mouse.move(0, 300)
}

/**
 * Clicks a group's root button for its own (default) action — e.g. Split
 * horizontally, Close pane. The menu now opens flush *over* the root button
 * rather than below it (see `.pane-header-dropdown` in global.css), so a
 * plain `.click()` here first moves the pointer onto the root — which,
 * exactly like hovering it deliberately, reveals the menu and hands the
 * hit-test to its covering first row instead of the root button
 * underneath. That row fires the identical action (it's the same `onPress`
 * the root button has, just repeated as the menu's own first item — never
 * a second, different control), so `force: true` here isn't papering over
 * a bug: it's just not asking Playwright to insist on an element identity
 * that no longer matters once the two are interchangeable outcomes.
 */
export const clickPaneRoot = (pane: Locator, testId: string): Promise<void> =>
  headerOf(pane).getByTestId(testId).click({ force: true })

// The root button's own default action — by far the most common setup step
// in the suite, so it gets a named wrapper like its vertical sibling below.
export const splitHorizontal = (pane: Locator): Promise<void> =>
  clickPaneRoot(pane, PANE_BUTTON.splitHorizontal)

export const openNewTab = (pane: Locator): Promise<void> =>
  openPaneMenuItem(pane, PANE_BUTTON.splitHorizontal, PANE_BUTTON.newTab)

export const splitVertical = (pane: Locator): Promise<void> =>
  openPaneMenuItem(pane, PANE_BUTTON.splitHorizontal, PANE_BUTTON.splitVertical)

export const openNewUnpinnedTab = (pane: Locator): Promise<void> =>
  openPaneMenuItem(pane, PANE_BUTTON.splitHorizontal, PANE_BUTTON.newUnpinnedTab)

export const wrapInTabGroup = (pane: Locator): Promise<void> =>
  openPaneMenuItem(pane, PANE_BUTTON.splitHorizontal, PANE_BUTTON.wrapInTabGroup)

export const clearPane = (pane: Locator): Promise<void> =>
  openPaneMenuItem(pane, PANE_BUTTON.close, PANE_BUTTON.clear)

export const closePane = (pane: Locator): Promise<void> => clickPaneRoot(pane, PANE_BUTTON.close)

// Assumes terminal registers first — see registerBuiltins.ts's own contract
// comment ("Registration order is the pane-header button order").
export const openNewBrowser = (pane: Locator): Promise<void> =>
  openPaneMenuItem(pane, 'pane-new-terminal-button', 'pane-new-browser-button')

// Same assumption, and same dropdown: the git tree registers last, so it is
// always a menu item under the terminal's root button rather than the root.
export const openNewGitTree = (pane: Locator): Promise<void> =>
  openPaneMenuItem(pane, 'pane-new-terminal-button', 'pane-new-git-tree-button')
