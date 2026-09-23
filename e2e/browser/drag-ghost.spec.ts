import { grabAndHover } from '../helpers/drag'
import { requireBox } from '../helpers/geometry'
import { headerOf, initialPane } from '../helpers/pane'
import { expect, test } from './helpers/harness'

// The source of a cross-window drag keeps receiving the gesture's pointer
// events after the cursor has left it (OS mouse capture — see
// main/layoutCrossWindow.ts), so its ghost must not draw for a pointer that
// is no longer over the window. Chromium cannot move a real pointer out of
// the viewport, so the move is dispatched, as floating.spec.ts does.
test('the drag ghost hides while the pointer is outside the window and comes back with it', async ({
  page
}) => {
  const header = headerOf(initialPane(page))
  const box = await requireBox(header)
  const inside = { x: box.x + box.width / 2 + 40, y: box.y + box.height + 40 }
  await grabAndHover(header, inside.x, inside.y)
  const ghost = page.locator('.drag-ghost')
  await expect(ghost).toBeVisible()

  const moveTo = (point: { x: number; y: number }) =>
    page.evaluate(({ x, y }) => {
      window.dispatchEvent(
        new PointerEvent('pointermove', {
          pointerId: 1,
          clientX: x,
          clientY: y,
          buttons: 1,
          bubbles: true
        })
      )
    }, point)

  await moveTo({ x: -200, y: inside.y })
  await expect(ghost).toHaveCount(0)
  await moveTo(inside)
  await expect(ghost).toBeVisible()

  await page.mouse.up()
  await expect(ghost).toHaveCount(0)
})

// A release with no local target holds the ghost until main says whether it
// landed in another window. A press arriving before that answer used to drop
// the answer without ending the held drag, so a click that never became a
// drag left it in the store for good: the ghost stuck on screen and spatial
// navigation off. The press has to land in the same task as the release —
// the fake bridge answers a microtask later — so both are dispatched.
test('a press before a targetless release is answered does not strand that drag', async ({
  page
}) => {
  const header = headerOf(initialPane(page))
  const headerBox = await requireBox(header)
  // Over the dragged pane's own body, which is never a target.
  const body = await requireBox(initialPane(page))
  await grabAndHover(header, body.x + body.width / 2, body.y + body.height / 2)
  await expect(page.locator('.drag-ghost')).toBeVisible()

  await page.evaluate(
    ({ x, y }) => {
      const at = { pointerId: 1, clientX: x, clientY: y, bubbles: true }
      window.dispatchEvent(new PointerEvent('pointerup', at))
      document
        .elementFromPoint(x, y)
        ?.dispatchEvent(new PointerEvent('pointerdown', { ...at, button: 0, buttons: 1 }))
      window.dispatchEvent(new PointerEvent('pointerup', at))
    },
    { x: headerBox.x + headerBox.width / 2, y: headerBox.y + headerBox.height / 2 }
  )

  await expect(page.locator('.drag-ghost')).toHaveCount(0)
})

// Relays do not time out, so a hung destination never sends the answer a
// targetless release waits on. Only a press on a tab or pane header used to
// give up on it, leaving the ghost up — and spatial navigation, which sits
// out a live drag, off — until the user happened to press one.
test('a targetless release main never answers is let go by the next press anywhere', async ({
  page
}) => {
  await page.evaluate(() => {
    type Bridge = { api: { layout: { sendCrossWindow: (message: { type: string }) => void } } }
    const layout = (window as unknown as Bridge).api.layout
    const send = layout.sendCrossWindow
    layout.sendCrossWindow = (message) => {
      if (message.type !== 'release') send(message)
    }
  })
  const header = headerOf(initialPane(page))
  const body = await requireBox(initialPane(page))
  await grabAndHover(header, body.x + body.width / 2, body.y + body.height / 2)
  await page.mouse.up()
  await page.waitForTimeout(300)
  // Held: no answer is coming.
  await expect(page.locator('.drag-ghost')).toBeVisible()

  // A press on the pane's body, not a header.
  await page.mouse.click(body.x + 20, body.y + body.height - 20)
  await expect(page.locator('.drag-ghost')).toHaveCount(0)
})
