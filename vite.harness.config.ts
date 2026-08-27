import { resolve } from 'node:path'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { sharedAlias } from './alias.config'

// Serves src/renderer/harness.html for the Playwright browser project (see
// playwright.config.ts's webServer) — a mirror of electron.vite.config.ts's
// renderer config, which electron-vite roots at src/renderer the same way.
export default defineConfig({
  root: resolve('src/renderer'),
  resolve: { alias: sharedAlias },
  plugins: [react()],
  // 127.0.0.1 explicitly: vite's default `localhost` binding can resolve to
  // ::1 only, and playwright.config.ts's webServer/baseURL probe 127.0.0.1.
  // No port here on purpose — playwright.config.ts passes --port/--strictPort,
  // derived from the checkout's path, so two worktrees never share a server
  // (see the harnessPort comment there). Started by hand without those flags,
  // this falls back to vite's own default port, which is fine for poking at
  // the harness manually but is not what the suite uses.
  server: { host: '127.0.0.1' }
})
