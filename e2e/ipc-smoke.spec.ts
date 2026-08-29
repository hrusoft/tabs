import { existsSync } from 'node:fs'
import path from 'node:path'
import type { Api } from '../src/shared/api'
import { expect, test } from './helpers/launch'
import { initialPane } from './helpers/pane'
import { openSettingsTab } from './helpers/settings'

// The fake window.api bridge (src/renderer/src/testing/fakeApi.ts) lets the
// jsdom and browser test tiers run without Electron — which also means a fake
// that drifted behaviorally from what preload really does could take those
// tiers green while the real integration broke. This spec is the backstop:
// every Api namespace keeps at least one real-Electron test exercising its
// actual IPC, named in the ledger below.
//
// A missing namespace is a compile error on both sides (each is an object
// literal annotated `Api`) before it can reach this file. What stays
// uncheckable, and what this spec covers, is *behavioral* drift: a fake that
// answers where the real bridge would fail. The `content` namespace is the
// generic bridge every content-type package speaks IPC through
// (shared/plugin/bridge.ts): its invoke/send/on plumbing plus the fake's twin
// (testing/content/index.ts) are exercised through each package's real
// traffic, so the per-package files on its row are what cover it.

/**
 * Which spec files each namespace's coverage lives in, with what each covers
 * beside it. `Record<keyof Api, ...>` is what makes a new namespace a compile
 * error here — the same shape pluginBoundaries.test.ts uses for its ledger —
 * and the test below is what makes a renamed or deleted spec fail here
 * instead of silently orphaning a namespace.
 */
const LEDGER_SPECS: Record<keyof Api, string[]> = {
  content: [
    // terminal traffic: ptys via invoke/send, data and exit via per-pane
    // events, cwd, dispose
    'terminal.spec.ts',
    // gitTree traffic: real repos — log, commit, defaultDirectory;
    // chooseDirectory only as far as its E2E_HIDDEN "cancelled" answer, since
    // a native picker is exactly what Playwright cannot drive
    'git-tree.spec.ts',
    // browser traffic: guest attach reports up, nav-key/pointer events down
    'browser.spec.ts',
    'keyboard-nav.spec.ts'
  ],
  // confirmClose: IPC round-trip only — the blocker *decision* is suppressed
  // under E2E_HIDDEN (see closeDialogs.ts); it's unit-covered instead
  pane: ['pane-header.spec.ts'],
  appWindow: [
    // isFullScreen / onFullScreenChange: the fullscreen bridge round-trip
    'root-tab-bar.spec.ts',
    // openSettings (and openSettingsWindow below)
    'settings.spec.ts',
    // openExternal: cmd-click link
    'terminal.spec.ts',
    // getAppInfoSync (the running version, which no other tier can see) and
    // copyText (the real system clipboard, which is the only place it lands)
    'about.spec.ts'
  ],
  // getSync/set/onChange: persistence + cross-window broadcast
  settings: ['settings.spec.ts'],
  // getSync/set: relaunch persistence
  layout: ['layout.spec.ts', 'titles.spec.ts'],
  shortcuts: [
    // onShortcut: real native menu items
    'pane-shortcuts.spec.ts',
    // setCaptureMode: accelerator suspension
    'keyboard-shortcuts.spec.ts'
  ],
  bell: ['bell.spec.ts'],
  // listFamilies
  fonts: ['ipc-smoke.spec.ts'],
  externalControl: ['external-control.spec.ts'],
  // status only — install/uninstall mutate the real ~/.claude etc. and stay
  // manual (a known gap)
  skills: ['ipc-smoke.spec.ts']
}

test('the coverage ledger names spec files that still exist', () => {
  for (const [namespace, specs] of Object.entries(LEDGER_SPECS)) {
    for (const spec of specs) {
      expect(
        existsSync(path.join('e2e', spec)),
        `${namespace}: ${spec} was renamed or removed — update the ledger in this file`
      ).toBe(true)
    }
  }
})

test('opens a window titled Tabs', async ({ page }) => {
  await expect(page).toHaveTitle('Tabs')
  // The pane rendering at all proves the renderer booted through the real
  // preload bridge: both stores read their state over synchronous IPC at
  // module init, so a broken bridge would leave nothing mounted. Root's own
  // wrapper is pane 0 (see ensureTabsRoot in tree.ts); initialPane is the
  // one real pane its lone default tab holds.
  await expect(initialPane(page)).toBeVisible()
})

test('fonts.listFamilies populates the settings font picker', async ({ page, electronApp }) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'terminal')

  // On macOS (this suite's platform — see helpers/global-setup.ts) the real
  // font registry answers with a non-empty list, which is what upgrades the
  // font-family control from a free-text input to a populated dropdown.
  const select = settingsPage.getByTestId('settings-terminal-font-family-select')
  await expect(select).toBeVisible()
  expect(await select.locator('option').count()).toBeGreaterThan(1)
})

test('skills.status resolves and fills the AI settings page', async ({ page, electronApp }) => {
  const settingsPage = await openSettingsTab(electronApp, page, 'ai')
  await expect(settingsPage.getByTestId('settings-page-ai')).toBeVisible()

  // "Loading…" clears only when the skills.status() round-trip lands; the
  // target list itself is machine-dependent, so assert no further.
  await expect(settingsPage.getByText('Loading…')).toHaveCount(0)
})
