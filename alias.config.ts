import { resolve } from 'node:path'

/**
 * The `@shared` alias, defined once for the three configs that can import
 * TypeScript: electron.vite.config.ts, vitest.config.ts and
 * vite.harness.config.ts. tsconfig.web.json cannot import anything, so its
 * `paths` entry is the one hand-synced copy left — a new alias goes here and
 * there, and nowhere else (see CLAUDE.md's src/shared entry).
 */
export const sharedAlias = { '@shared': resolve('src/shared') }
