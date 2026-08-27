import { resolve } from 'node:path'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'electron-vite'
import { sharedAlias } from './alias.config'

export default defineConfig({
  main: {},
  preload: {},
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
