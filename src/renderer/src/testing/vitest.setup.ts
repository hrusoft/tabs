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

afterEach(() => cleanup())
