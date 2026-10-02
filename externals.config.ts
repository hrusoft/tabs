import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

interface PackageJson {
  dependencies?: Record<string, string>
}

function readPackageJson(dir: string): PackageJson {
  return JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')) as PackageJson
}

/**
 * Every third-party runtime dependency any workspace package declares — the
 * root's own `dependencies` plus each `packages/<name>/package.json`'s,
 * `@tabs/*` names excluded (those are sibling workspace packages, not npm
 * packages). Sorted, deduplicated.
 *
 * This exists because two tools only ever read the *root* package.json, and
 * issue #18 moved every runtime dependency off the root and onto the package
 * that uses it (node-pty and @xterm/* now live in
 * packages/plugin-terminal/package.json):
 *
 * - electron-vite externalizes the root's `dependencies` in the main and
 *   preload builds and bundles everything else. With the root's list empty it
 *   silently *bundled node-pty* into out/main/index.js — the build succeeded,
 *   and every launch died in main with "Failed to load native module:
 *   pty.node", which Electron answers with a native error dialog even under
 *   E2E_HIDDEN. electron.vite.config.ts passes this list as
 *   `build.externalizeDeps.include`, which restores exactly the set the root
 *   used to declare.
 * - the attributions gate (src/shared/__tests__/attributions.test.ts) credits
 *   "what ships", which is this same union.
 *
 * Derived rather than hand-listed so a package adding a runtime dependency to
 * its own package.json is externalized and attributed with no second edit.
 */
export function workspaceRuntimeDependencies(root = resolve('.')): string[] {
  const packagesDir = join(root, 'packages')
  const packageDirs = readdirSync(packagesDir)
    .map((name) => join(packagesDir, name))
    .filter((dir) => statSync(dir).isDirectory())
  const names = [root, ...packageDirs].flatMap((dir) =>
    Object.keys(readPackageJson(dir).dependencies ?? {})
  )
  return [...new Set(names.filter((name) => !name.startsWith('@tabs/')))].sort()
}
