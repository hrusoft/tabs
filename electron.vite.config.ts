import { resolve } from 'node:path'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'electron-vite'
import { sharedAlias } from './alias.config'
import { workspaceRuntimeDependencies } from './externals.config'

// electron-vite only externalizes the *root* package.json's dependencies, and
// every runtime dependency now lives on the workspace package that uses it
// (see externals.config.ts) — without this, node-pty is bundled into main and
// the app dies at launch loading its native binding.
const externalizeDeps = { include: workspaceRuntimeDependencies() }

export default defineConfig({
  main: {
    build: { externalizeDeps }
  },
  preload: {
    build: { externalizeDeps }
  },
  renderer: {
    resolve: {
      alias: sharedAlias
    },
    plugins: [react()],
    build: {
      rollupOptions: {
        input: {
          index: resolve('src/renderer/index.html'),
          settings: resolve('src/renderer/settings.html'),
          about: resolve('src/renderer/about.html')
        }
      }
    }
  }
})
