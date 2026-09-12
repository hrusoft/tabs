import { test as base, expect, type Page } from '@playwright/test'
import type { ShortcutActionId } from '../../../src/shared/shortcuts'
import type {
  ExtraStubType,
  FakeApiHandle,
  TestSeed
} from '../../../src/shared/testing/fakeApiHandle'

// The same augmentation fakeApi.ts declares for the web project — the two
// tsconfig projects can't share it, so each declares it against the one
// shared FakeApiHandle type.
declare global {
  interface Window {
    __fakeApi?: FakeApiHandle
    __tabsTestSeed?: TestSeed
    __tabsTestExtraContent?: ExtraStubType[]
  }
}

interface HarnessOptions {
  /** Initial settings/layout the harness boots with — set per file/describe via test.use. */
  seed: TestSeed
  /** Extra stub content types to register before mounting — see ExtraStubType for each, and why they are opt-in. */
  extraContentTypes: ExtraStubType[]
}

/**
 * Fixtures for the browser project (plain Chromium + the vite-served harness,
 * see playwright.config.ts): every test gets a fresh page already showing the
 * app — seed installed ahead of the page's own scripts, since the stores read
 * it during module init. A fresh page per test IS the reset story here; never
 * import ../helpers/launch (Electron) from a browser spec. Script the bridge
 * through window.__fakeApi via page.evaluate.
 */
export const test = base.extend<HarnessOptions>({
  seed: [{}, { option: true }],
  extraContentTypes: [[], { option: true }],
  page: async ({ page, seed, extraContentTypes }, use) => {
    await page.addInitScript((value) => {
      window.__tabsTestSeed = value
    }, seed)
    await page.addInitScript((value) => {
      window.__tabsTestExtraContent = value
    }, extraContentTypes)
    await page.goto('/harness.html')
    await expect(page.getByTestId('pane').first()).toBeVisible()
    await use(page)
  }
})

export { expect } from '@playwright/test'

/**
 * Applies a settings change at runtime through the same settings.onChange
 * path a real cross-window edit takes (settingsStore's mirror subscription).
 */
export function emitSettingsChange(page: Page, partial: Record<string, unknown>): Promise<void> {
  return page.evaluate((value) => {
    window.__fakeApi?.emitSettingsChange(value)
  }, partial)
}

/**
 * Fires one shortcut action's `shortcuts.onShortcut` callbacks — the exact
 * contract its File/Edit menu item drives over IPC (the menu → IPC wiring
 * itself keeps a real Electron smoke test in e2e/pane-shortcuts.spec.ts).
 *
 * `new-unpinned-pane` is here rather than in the jsdom tier because its spawn
 * geometry (a section of the active pane, with spacing) needs real layout.
 */
export function fireShortcut(page: Page, id: ShortcutActionId): Promise<void> {
  return page.evaluate((action) => {
    window.__fakeApi?.fireShortcut(action)
  }, id)
}
