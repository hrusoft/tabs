import { readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { expect, test } from 'vitest'

/**
 * Nothing that runs in the main process may switch the app's activation
 * policy: no Dock hide or show, no `setActivationPolicy` call. That covers
 * core main, every package's main entry, and the e2e harness, whose
 * `electronApp.evaluate` callbacks run inside the app's main process too.
 *
 * On macOS 27, loginwindow watches for an app leaving the Dock. When one
 * does, it asks background task management whether the app may run in the
 * background, and if the answer is no it force-quits the app 30s later,
 * provided the app has never shown a window. Every e2e app qualifies, since
 * none ever shows one. A Dock hide at startup under E2E_HIDDEN was the cause
 * of the suite's "accepted" flakes: 1-2 shared apps SIGTERMed per full run,
 * failing whatever test was mid-flight on them. The harness now keeps e2e
 * apps out of the Dock the other way, by launching them from an
 * `LSUIElement` clone of Electron.app, which e2e/harness.spec.ts checks at
 * runtime. With the clone, a hide is harmless but a show is not (the app
 * gains a Dock tile and is policed from then on), and without the clone any
 * hide brings the kills straight back. So both are refused here, and this is
 * the cheap layer: a re-added call fails `npm test` with its file and line.
 *
 * If a shipping feature ever genuinely needs one, it must be unreachable
 * under `e2eHidden`, and its file goes in ALLOWED as a deliberate edit to
 * this test.
 *
 * The scan skips comment lines, so prose may name the calls. It is a text
 * match, not a parser: a destructured `dock` or a computed member name would
 * get past it, and it isn't trying to catch those.
 */

const root = path.resolve(import.meta.dirname, '../../..')

/** Repo-relative files allowed to switch the activation policy. None today. */
const ALLOWED = new Set<string>()

const SWITCH = /\.dock\s*\??\.\s*(?:hide|show)\b|\bsetActivationPolicy\b/

const SOURCE = /\.(?:[cm]?[jt]s|tsx)$/

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '__tests__') continue
    const p = path.join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (SOURCE.test(name)) out.push(p)
  }
  return out
}

function scannedFiles(): string[] {
  const roots = [path.join(root, 'src/main'), path.join(root, 'e2e')]
  for (const pkg of readdirSync(path.join(root, 'packages'))) {
    const main = path.join(root, 'packages', pkg, 'main')
    try {
      if (statSync(main).isDirectory()) roots.push(main)
    } catch {
      // A package with no main entry has nothing to scan.
    }
  }
  return roots.flatMap((dir) => walk(dir))
}

/** The line with any comment removed, or '' for a line that is all comment. */
function codeOf(line: string): string {
  const trimmed = line.trimStart()
  if (trimmed.startsWith('//') || trimmed.startsWith('/*') || trimmed.startsWith('*')) return ''
  return line.replace(/\s\/\/\s.*$/, '')
}

test('the scan covers core main, every package main entry, and the e2e harness', () => {
  const files = scannedFiles().map((file) => path.relative(root, file))
  expect(files).toContain('src/main/index.ts')
  expect(files).toContain('packages/plugin-terminal/main/index.ts')
  expect(files).toContain('e2e/helpers/launch.ts')
})

test('nothing in the main process or the e2e harness switches the activation policy', () => {
  const offenders: string[] = []
  for (const file of scannedFiles()) {
    const rel = path.relative(root, file)
    if (ALLOWED.has(rel)) continue
    readFileSync(file, 'utf8')
      .split('\n')
      .forEach((line, index) => {
        if (SWITCH.test(codeOf(line))) offenders.push(`${rel}:${index + 1}: ${line.trim()}`)
      })
  }
  expect(offenders, 'activation-policy switches (see this test file for why)').toEqual([])
})
