import type { Locator, Page } from '@playwright/test'
import { centerOf, requireBox } from './geometry'

/**
 * Presses on `handle` at its midpoint, drags to an absolute point, and
 * releases — the plain complete gesture, with no engage threshold to cross
 * (floating-window chrome and resize edges respond to the first move).
 * `grabAndHover` below is the deliberately-incomplete variant.
 */
export async function dragTo(handle: Locator, x: number, y: number): Promise<void> {
  const page = handle.page()
  const from = centerOf(await requireBox(handle))
  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  await page.mouse.move(x, y, { steps: 10 })
  await page.mouse.up()
}

/**
 * Grabs `source` (a pane header, tab, or grip) and drags to (x, y) without
 * releasing: press, a small move to cross the 5px engage threshold, then the
 * real destination. The caller asserts mid-drag state and releases with
 * `page.mouse.up()` itself.
 */
export async function grabAndHover(source: Locator, x: number, y: number): Promise<void> {
  const page = source.page()
  const from = centerOf(await requireBox(source))
  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  await page.mouse.move(from.x + 20, from.y + 10, { steps: 5 })
  await page.mouse.move(x, y, { steps: 10 })
}

/** `grabAndHover` aimed at the centre of `target` — the common "drag onto that pane" gesture. */
export async function grabAndHoverCenter(source: Locator, target: Locator): Promise<void> {
  const { x, y } = centerOf(await requireBox(target))
  await grabAndHover(source, x, y)
}

/**
 * Waits out a hovered tab's spring-load delay mid-drag, with enough headroom
 * for a loaded machine to have fired the timer.
 *
 * One helper rather than a literal per test because the number is not the
 * test's to pick: it has to stay above dragController's SPRING_LOAD_DELAY_MS,
 * and six hand-written 600/650/700s across two tiers is six things to find on
 * the day that constant moves — and a test that silently stops waiting long
 * enough asserts that spring-loading *didn't* happen, which is a passing test
 * for several of these.
 */
export async function holdPastSpringLoad(page: Page): Promise<void> {
  await page.waitForTimeout(SPRING_LOAD_HOLD_MS)
}

const SPRING_LOAD_HOLD_MS = 700

/**
 * Finishes an in-progress drag by releasing inside `pane`'s right-edge dock
 * zone, i.e. "split this pane and put the dragged thing in the new half".
 *
 * The fraction is the magic number worth naming: it has to sit inside the edge
 * band dragController previews but clear of the pane's own chrome, and a test
 * that guesses it slightly wrong drops in the *centre* zone instead — which
 * docks as a tab, still passes several of the assertions around it, and
 * silently stops testing splitting at all.
 */
export async function releaseOnRightEdge(pane: Locator): Promise<void> {
  const page = pane.page()
  const box = await requireBox(pane)
  await page.mouse.move(box.x + box.width * 0.82, box.y + box.height * 0.5, { steps: 5 })
  await page.mouse.up()
}

/**
 * Presses a vertical separator at its midpoint and drags it horizontally
 * through each offset in turn (relative to where the press landed), releasing
 * at the last — several offsets model a drag that reverses mid-gesture without
 * lifting the button.
 *
 * Unlike the app's own pane/tab drags there's no engage threshold to cross, so
 * this presses and moves straight to the destination rather than going through
 * `grabAndHover`. The `steps: 10` matters and is not cosmetic: each
 * intermediate move is one `onLayoutChange` tick, and cluster mirroring only
 * arms once `wasCoDraggedLastTick()` has a settled prior tick to answer from
 * (see separatorRegistry.ts). A single-step drag never gets there.
 */
export async function dragSeparatorX(separator: Locator, ...offsets: number[]): Promise<void> {
  const page = separator.page()
  const box = await requireBox(separator)
  const y = box.y + box.height / 2
  const startX = box.x + box.width / 2
  await page.mouse.move(startX, y)
  await page.mouse.down()
  for (const dx of offsets) await page.mouse.move(startX + dx, y, { steps: 10 })
  await page.mouse.up()
}

/** Drags a vertical separator so its box's left edge ends up at the given absolute page x. */
export async function dragSeparatorToX(separator: Locator, targetX: number): Promise<void> {
  const box = await requireBox(separator)
  await dragSeparatorX(separator, targetX - box.x)
}
