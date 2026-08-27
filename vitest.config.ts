import { defineConfig } from 'vitest/config'
import { sharedAlias as alias } from './alias.config'

// Two tiers, split by extension: `.test.ts` files are plain node unit tests;
// `.test.tsx` files are jsdom component tests mounting the real renderer with
// the fake window.api bridge (src/renderer/src/testing/) installed by the
// setup file before any test module's imports run.
export default defineConfig({
  test: {
    projects: [
      {
        resolve: { alias },
        test: {
          name: 'unit',
          environment: 'node',
          include: ['src/**/__tests__/**/*.test.ts']
        }
      },
      {
        resolve: { alias },
        // The root tsconfig.json carries no compilerOptions, so esbuild never
        // sees tsconfig.web.json's "jsx": "react-jsx" — state it here.
        esbuild: { jsx: 'automatic' },
        test: {
          name: 'components',
          environment: 'jsdom',
          include: ['src/**/__tests__/**/*.test.tsx'],
          // Order matters: the polyfills must run before react-dom's module
          // init, which the second file's RTL import triggers.
          setupFiles: [
            'src/renderer/src/testing/vitest.polyfills.ts',
            'src/renderer/src/testing/vitest.setup.ts'
          ]
        }
      }
    ]
  }
})
