import type { Api } from '../src/shared/api'
import { IpcChannel } from '../src/shared/ipc'
import { REATTACH_GRACE_MS } from '../src/shared/reattach'
import { expect, test } from './helpers/launch'
import { initialPane, wrapInTabGroup } from './helpers/pane'
import { openSettingsWindow } from './helpers/settings'
import { alive, openTerminal } from './helpers/terminal'

// Replaces the old window-header.spec.ts: the main window's root is always a
// tab group now (see ensureTabsRoot in tree.ts), so there is no separate
// "wrap the whole window" button any more — its own tab bar plays that role
// permanently (TabBar.tsx's isRoot branch), and offers no Split/Wrap in tab
// group of its own (PaneHeaderControls.tsx's isDockedRoot branch), all of
// which is covered structurally in app.test.tsx and pane-header.test.tsx
// (jsdom). What's left here is what only real, multi-window Electron can
// prove: a live pty surviving the same kind of structural wrap the old test
// guarded (now exercised via the per-pane wrap control, since the root
// itself can no longer be wrapped at all), and the real Settings window
// actually opening from the root bar's own button.
//
// The old test's one irreplaceable case — wrapping a *split* as a whole,
// which no per-pane chrome can reach since a split hosts no chrome of its
// own — doesn't have an equivalent any more: that capability lived only in
// the removed whole-window button, and was never extended to a non-root
// split. The reattach guarantee itself isn't split-specific, though, so
// wrapping a single live pane below still exercises exactly the same
// registry (see reattachRegistry.ts).

test('wrapping a live terminal pane into a tab group keeps its shell alive', async ({
  page,
  electronApp
}) => {
  const term = await openTerminal(initialPane(page))
  const pid = Number(await term.getAttribute('data-pty-pid'))

  await wrapInTabGroup(initialPane(page))

  // Root's own tablist is untouched; a new, nested one opened just for the
  // pane that was just wrapped.
  await expect(page.getByRole('tablist')).toHaveCount(2)
  await expect(page.getByRole('tablist').nth(1).getByRole('tab')).toHaveCount(1)

  // Same shell, no restart — outliving the disposal grace makes it real.
  await expect(term).toHaveAttribute('data-pty-pid', String(pid))
  await page.waitForTimeout(REATTACH_GRACE_MS * 2)
  expect(await alive(electronApp, pid)).toBe(true)
})

test("the root tab bar's own Settings button opens the real Settings window", async ({
  page,
  electronApp
}) => {
  const settingsPage = await openSettingsWindow(electronApp, page)
  await expect(settingsPage.getByTestId('settings-page-general')).toBeVisible()
  expect(electronApp.windows()).toHaveLength(2)
})

test('fullscreen collapses the root bar into an ordinary tab bar', async ({
  page,
  electronApp
}) => {
  test.skip(process.platform !== 'darwin', 'the traffic-light gutter is macOS-only chrome')

  const barMetrics = () =>
    page.evaluate(() => {
      const bar = document.querySelector('.tab-bar-root') as HTMLElement
      const style = getComputedStyle(bar)
      return { paddingLeft: style.paddingLeft, height: style.height }
    })

  // Out of fullscreen: the traffic-light gutter plus the taller title-bar
  // height (30px — see trafficLightPosition in main/windows.ts). The initial
  // read also rides the real invoke channel end to end. (The `window.api`
  // typing lives in the renderer tsconfig; this spec compiles under the node
  // one, hence the cast.)
  expect(
    await page.evaluate(() => (window as unknown as { api: Api }).api.appWindow.isFullScreen())
  ).toBe(false)
  expect(await barMetrics()).toEqual({ paddingLeft: '108px', height: '30px' })

  // The change event over the real channel and preload bridge — this is the
  // real-IPC coverage for appWindow.onFullScreenChange (see ipc-smoke.spec.ts's
  // map). Sent from main directly rather than via win.setFullScreen(true):
  // macOS never actually fullscreens the never-shown E2E_HIDDEN window, so
  // its enter-full-screen event — the two-line wiring in main/windows.ts that
  // emits on this channel — can't fire here and stays covered by eyes only.
  const send = (value: boolean) =>
    electronApp.evaluate(
      ({ BrowserWindow }, [channel, flag]) =>
        BrowserWindow.getAllWindows()[0]!.webContents.send(channel as string, flag),
      [IpcChannel.windowFullScreenChanged, value] as const
    )

  await send(true)
  // 7px is a nested bar's own --depth-indent padding and 24px its height —
  // in fullscreen macOS hides the traffic lights, and the root bar reads
  // exactly like a nested one.
  await expect.poll(barMetrics).toEqual({ paddingLeft: '7px', height: '24px' })

  await send(false)
  await expect.poll(barMetrics).toEqual({ paddingLeft: '108px', height: '30px' })
})
