import { execFile } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import type { AddressInfo } from 'node:net'
import { createServer as createNetServer } from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { promisify } from 'node:util'
import type { Locator, Page } from '@playwright/test'
import type { ElectronApplication } from 'playwright'
import type {
  ElementDescription,
  PageElement
} from '../../src/plugins/browser/shared/externalControl'
import { PANE_ATTR } from '../../src/shared/paneDomAttrs'
import { openBrowser } from './browser'
import { expect } from './launch'
import { closeInactiveRootTab, closePane, initialPane, paneById } from './pane'
import { openSettingsTab } from './settings'
import { openTerminal, typeAndEnter } from './terminal'

/**
 * The agent-control session scaffolding every external-control-*.spec.ts
 * shares: running the real bundled tabs-ctl binary, opening a terminal
 * session and reading its control env, creating/closing agent panes, and the
 * per-verb-family ownership refusal scaffold. Split out when the one
 * external-control spec (3,700 lines, 69 tests, 60+ real-terminal opens)
 * became the Electron suite's whole wall clock — with a worker owning one
 * file at a time, three workers idled while one walked it serially.
 */

const execFileAsync = promisify(execFile)
const TABS_CTL = path.resolve(
  import.meta.dirname,
  '..',
  '..',
  'resources/skills/tabs/scripts/tabs-ctl'
)

/**
 * An origin that refuses connections: an ephemeral port briefly owned and
 * closed again. A fixed low port won't do — Chromium refuses its unsafe-port
 * list (1, 7, …) with ERR_UNSAFE_PORT before ever dialing it, which is a
 * different failure than the ERR_CONNECTION_REFUSED a down dev server gives.
 */
export function deadOrigin(): Promise<string> {
  return new Promise((resolve) => {
    const server = createNetServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo
      server.close(() => resolve(`http://127.0.0.1:${port}/`))
    })
  })
}

/** The control env a Tabs terminal's pty carries (see readPaneEnv). */
export type PaneEnv = { TABS_CONTROL_SOCKET: string; TABS_PANE_ID: string }

/**
 * Runs the real bundled tabs-ctl binary from this test-runner process (not
 * from inside the pty) against the socket path/pane id captured from a real
 * terminal's environment — this exercises the actual production path (real
 * Unix socket, real src/main/externalControl.ts, real renderer relay) with a
 * far more reliable client than screen-scraping JSON out of a terminal's
 * rendered text. tabs-ctl always prints one JSON line and exits non-zero on
 * `{"ok":false}`, so a rejected execFile still carries the JSON on stdout.
 */
export function runTabsCtl(
  args: string[],
  env: Partial<PaneEnv>
): Promise<{
  ok: boolean
  error?: string
  result?: {
    paneId?: string
    panes?: { paneId: string; url: string; title: string }[]
    title?: string
    url?: string
    viewport?: { width: number; height: number }
    text?: string
    truncated?: boolean
    isLoading?: boolean
    readyState?: string
    settled?: boolean
    frames?: number
    shadowRoots?: number
    loaded?: boolean
    loadError?: string
    redirected?: boolean
    status?: number
    statusText?: string
    titleFromUrl?: boolean
    retried?: boolean
    firstUrl?: string
    position?: { x: number; y: number }
    x?: number
    y?: number
    element?: ElementDescription
    path?: string
    bytes?: number
    contentType?: string
    format?: string
    serializedResult?: unknown
    width?: number
    height?: number
    scaleFactor?: number
    clipped?: { x: number; y: number; width: number; height: number }
    activated?: boolean
    pngBytes?: unknown
    elements?: PageElement[]
    total?: number
    offset?: number
    matches?: { ref: string; name: string; score: number }[]
    messages?: { seq: number; level: string; text: string }[]
    value?: unknown
    filled?: number
    fields?: { index: number; length: number }[]
    errors?: { index: number; error: string }[]
    steps?: {
      type?: string
      ok?: boolean
      durationMs?: number
      skipped?: boolean
      error?: string
      result?: { text?: string; elapsedMs?: number }
    }[]
    note?: string
    command?: string
    showingErrorPage?: boolean
    hidden?: boolean
    stoppedAt?: number
    elapsedMs?: number
    ref?: string
    tag?: string
    rect?: { x: number; y: number; width: number; height: number }
    // The network/console entry shapes are wire-local (assembled in main from
    // its own log types), so unlike `elements` they have no shared type to
    // compose from.
    requests?: {
      seq: number
      method: string
      url: string
      resourceType?: string
      status?: number
      error?: string
      startedAt?: number
      completedAt?: number
      count?: number
      firstStartedAt?: number
      requestHeaders?: Record<string, string>
      responseHeaders?: Record<string, string>
      responseBody?: {
        body?: string
        truncated?: boolean
        size?: number
        mimeType?: string
        binary?: boolean
      }
    }[]
    bodyCapture?: string
    enabled?: boolean
    maxBodyChars?: number
    seq?: number
    count?: number
  }
  /** tabs-ctl's process exit code — the shell contract (`&&`) the skill documents. */
  exitCode?: number
}> {
  // `env` is authoritative, including when it's empty: developing Tabs inside
  // Tabs means this test process can itself inherit a real TABS_PANE_ID /
  // TABS_CONTROL_SOCKET, which would otherwise point tabs-ctl at the
  // developer's own running app instead of the one under test — silently
  // passing the ownership tests against the wrong process, and failing the
  // "outside Tabs" test that depends on those vars being absent.
  const base = { ...process.env }
  delete base.TABS_CONTROL_SOCKET
  delete base.TABS_PANE_ID
  return execFileAsync(TABS_CTL, args, { env: { ...base, ...env } }).then(
    ({ stdout }) => ({ ...JSON.parse(stdout.trim()), exitCode: 0 }),
    (error: { stdout?: string; code?: number | string }) => ({
      ...JSON.parse(error.stdout ?? '{}'),
      exitCode: typeof error.code === 'number' ? error.code : 1
    })
  )
}

/**
 * Reads the real TABS_CONTROL_SOCKET/TABS_PANE_ID Tabs injected into this
 * terminal's pty (see terminal.ts's env: { ...process.env,
 * TABS_CONTROL_SOCKET, TABS_PANE_ID }) by having the shell write them to a
 * file this process then reads directly — screen-scraping xterm's rendered
 * text is fragile here since the socket path is long enough to word-wrap in
 * a narrow test pane.
 */
export async function readPaneEnv(term: Locator): Promise<PaneEnv> {
  const dir = mkdtempSync(path.join(tmpdir(), 'tabs-e2e-env-'))
  const file = path.join(dir, 'env.txt')
  try {
    await typeAndEnter(term, `printf '%s\\n%s\\n' "$TABS_CONTROL_SOCKET" "$TABS_PANE_ID" > ${file}`)
    await expect
      .poll(() => (existsSync(file) ? readFileSync(file, 'utf-8').trim().split('\n').length : 0))
      .toBe(2)
    const [socket, paneId] = readFileSync(file, 'utf-8').trim().split('\n')
    return { TABS_CONTROL_SOCKET: socket!, TABS_PANE_ID: paneId! }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/**
 * The prologue nearly every test shares: a real terminal in the initial
 * pane (root's own default tab — see `initialPane`), and the control env
 * its pty carries.
 */
export async function openAgentSession(page: Page): Promise<{ term: Locator; env: PaneEnv }> {
  const term = await openTerminal(initialPane(page))
  const env = await readPaneEnv(term)
  return { term, env }
}

/**
 * create-browser-pane plus the paneId guard every non-creation test repeats.
 * For tests where creation itself is the subject (its ok/loaded/loadError
 * fields), call runTabsCtl directly and assert on the raw response instead.
 */
export async function createAgentPane(env: PaneEnv, ...args: string[]): Promise<string> {
  const created = await runTabsCtl(['create-browser-pane', ...args], env)
  const paneId = created.result?.paneId
  if (!paneId) throw new Error('createBrowserPane did not return a paneId')
  return paneId
}

/**
 * Switches Settings → Browser → "New pane placement", the setting
 * handleCreateBrowserPane (src/plugins/browser/renderer/browserExternalControl.ts)
 * reads to decide where create-browser-pane places its new pane. Applies live
 * — no save button, no window close needed — the same as every other
 * settings-window test in this suite.
 */
export async function setControlledPanePlacement(
  page: Page,
  electronApp: ElectronApplication,
  placement: 'tab' | 'split-horizontal' | 'split-vertical' | 'unpinned'
): Promise<void> {
  const settingsPage = await openSettingsTab(electronApp, page, 'browser')
  await settingsPage
    .getByTestId('settings-browser-controlled-pane-placement-select')
    .selectOption(placement)
}

/**
 * The standard teardown: close the agent's pane over the socket (when one
 * was created), then the terminal pane via its own header — the browser
 * pane's close collapsed the tab group, so the terminal has a plain header
 * again. Tests where the terminal is still wrapped in a group use
 * `closeInactiveRootTab` instead.
 */
export async function closeAgentSession(page: Page, env: PaneEnv, paneId?: string): Promise<void> {
  if (paneId) await runTabsCtl(['close-pane', '--pane', paneId], env)
  await closePane(paneById(page, env.TABS_PANE_ID))
}

/** A browser pane the user opened by hand — never targetable by an agent. */
export async function openForeignPane(page: Page, env: PaneEnv): Promise<string> {
  await openBrowser(paneById(page, env.TABS_PANE_ID))
  const foreign = await page.locator(`[${PANE_ATTR.dock}]`).last().getAttribute(PANE_ATTR.dock)
  if (!foreign) throw new Error('could not find the hand-opened pane')
  return foreign
}

// Here, "the inactive root tab" always means the terminal's: an agent's own
// pane (or a hand-opened foreign one) lands as a sibling tab in root's own
// group and activates, backgrounding the terminal — whose tab was never
// retitled to "Terminal" in the first place (see closeInactiveRootTab's doc
// in helpers/pane.ts). Covers the case `closeAgentSession` doesn't: a
// browser pane still sitting beside the terminal in root's group.

/**
 * The shared scaffold of the per-verb-family ownership tests: a session, a
 * hand-opened foreign pane, and the assertion that every listed command is
 * refused with the ownership error.
 */
export async function expectRefusedForForeignPane(
  page: Page,
  commands: (foreign: string) => string[][]
): Promise<void> {
  const { env } = await openAgentSession(page)
  const foreign = await openForeignPane(page, env)
  for (const args of commands(foreign)) {
    const response = await runTabsCtl(args, env)
    expect(response.ok, `${args[0]} should be refused`).toBe(false)
    expect(response.error).toContain('not the owner')
  }
  await closeInactiveRootTab(page)
}
