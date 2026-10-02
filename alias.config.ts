import { resolve } from 'node:path'

/**
 * The `@shared` alias, defined once for the three configs that can import
 * TypeScript: electron.vite.config.ts, vitest.config.ts and
 * vite.harness.config.ts. tsconfig.web.json cannot import anything, so its
 * `paths` entry is the one hand-synced copy left — a new alias goes here and
 * there, and nowhere else (see CLAUDE.md's src/shared entry).
 *
 * The plugin-facing surface now lives in the real `@tabs/plugin-sdk`
 * workspace package (packages/plugin-sdk) — resolved through ordinary
 * node_modules resolution via its `package.json#exports` map, so it needs
 * no alias here at all (issue #18's `@sdk` staging alias is gone).
 */
export const sharedAlias = { '@shared': resolve('src/shared') }
