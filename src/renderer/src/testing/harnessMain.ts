import '../styles/global.css'
import { createFakeApi } from './fakeApi'

// The Playwright browser tier's entry (harness.html): the real renderer in a
// plain Chromium page, with the fake bridge where preload would be. The
// bridge must exist before any module that reads it at import time
// (layoutStore/settingsStore call window.api.*.getSync() at module eval —
// see CLAUDE.md), and static imports hoist above statements, so the app is
// entered only through the dynamic import below.

declare global {
  interface Window {
    /**
     * Set only by native/Visual/capture-electron.mjs (via page.addInitScript):
     * the git tree history a visual-comparison scenario seeds, which also
     * registers the git tree — see registerGitTreeVisualCapture.
     */
    __tabsVisualGitTree?: unknown
    /**
     * Set only by the same script: the browser panes' stand-in pages a
     * visual-comparison scenario seeds, by pane id, and whether empty panes
     * offer "New browser", which registers the browser — see registerBrowserVisualCapture.
     */
    __tabsVisualBrowser?: unknown
    /**
     * Set only by the same script: how many extra creation-capable stub types
     * (after the harness's own) the command palette scenario `palette-many` lists.
     */
    __tabsVisualPaletteTypes?: number
  }
}

const handle = createFakeApi(window.__tabsTestSeed)
window.api = handle.api
window.__fakeApi = handle

// installTheme rides the same dynamic import for the same reason: it reads the
// settings store, which reads the bridge at module-eval time. It has to run
// here rather than inside mountTestApp so the browser tier boots exactly the
// way the real entry points do — tokens applied before the first render.
// installCaffeinate rides along for a sharper reason than "matches
// main.tsx": it is no longer wired from an effect in <App/> at all (see
// main.tsx's module comment), so a harness that skipped it here would have
// no caffeinate wiring, silently, forever.
const gitTreeSeed = window.__tabsVisualGitTree
const browserSeed = window.__tabsVisualBrowser
const paletteTypes = window.__tabsVisualPaletteTypes
void Promise.all([
  import('../core/theme/installTheme'),
  import('../caffeinate/installCaffeinate'),
  import('./mountTestApp'),
  gitTreeSeed === undefined
    ? undefined
    : import('./registerTestContent').then(({ registerGitTreeVisualCapture }) =>
        registerGitTreeVisualCapture(gitTreeSeed)
      ),
  browserSeed === undefined
    ? undefined
    : import('./registerTestContent').then(({ registerBrowserVisualCapture }) =>
        registerBrowserVisualCapture(browserSeed)
      ),
  // The stub first (registerTestContent is idempotent), so the extras follow it in the list.
  paletteTypes === undefined
    ? undefined
    : import('./registerTestContent').then(
        ({ registerPaletteVisualTypes, registerTestContent }) => {
          registerTestContent()
          registerPaletteVisualTypes(paletteTypes)
        }
      )
]).then(([{ installTheme }, { installCaffeinate }, { mountTestApp }]) => {
  installTheme()
  installCaffeinate()
  mountTestApp()
})
