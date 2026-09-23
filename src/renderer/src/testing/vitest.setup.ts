import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'
import { createFakeApi } from './fakeApi'

// jsdom gap-fills live in vitest.polyfills.ts, which runs before this file:
// react-dom's environment sniffing happens at its module init, i.e. inside
// this file's RTL import, so anything react-dom must see cannot live here.

// The fake bridge must exist before any renderer module is imported:
// layoutStore and settingsStore call window.api.*.getSync() at module-eval
// time (the sync-IPC-at-init pattern — see CLAUDE.md). Setup files run before
// test-file imports, so this is the one place early enough.
const handle = createFakeApi()
window.api = handle.api
window.__fakeApi = handle

// installCaffeinate is no longer wired from an effect in <App/> — it has to
// run once, before any render, the same as in main.tsx (see its module
// comment). Setup files run once per test file, not per test, which is
// exactly right here: the subscription itself is process-lifetime, and
// renderApp()'s per-test resetStores() puts caffeinateStore back to a known
// state without needing to reinstall it.
//
// A dynamic import, not a static one: a static `import { installCaffeinate }`
// at the top of this file would hoist above the `window.api = handle.api`
// assignment above (this is exactly the trap harnessMain.ts's own comment
// describes) — installCaffeinate's module graph reaches caffeinateStore.ts,
// which reads `window.api.caffeinate.isRunningSync()` at its own module-eval
// time, so it must not load until the bridge genuinely exists.
const { installCaffeinate } = await import('../caffeinate/installCaffeinate')
installCaffeinate()

afterEach(() => cleanup())
