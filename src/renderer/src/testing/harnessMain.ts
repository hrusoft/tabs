import '../styles/global.css'
import { createFakeApi } from './fakeApi'

// The Playwright browser tier's entry (harness.html): the real renderer in a
// plain Chromium page, with the fake bridge where preload would be. The
// bridge must exist before any module that reads it at import time
// (layoutStore/settingsStore call window.api.*.getSync() at module eval —
// see CLAUDE.md), and static imports hoist above statements, so the app is
// entered only through the dynamic import below.

const handle = createFakeApi(window.__tabsTestSeed)
window.api = handle.api
window.__fakeApi = handle

// installTheme rides the same dynamic import for the same reason: it reads the
// settings store, which reads the bridge at module-eval time. It has to run
// here rather than inside mountTestApp so the browser tier boots exactly the
// way the real entry points do — tokens applied before the first render.
void Promise.all([import('../core/theme/installTheme'), import('./mountTestApp')]).then(
  ([{ installTheme }, { mountTestApp }]) => {
    installTheme()
    mountTestApp()
  }
)
