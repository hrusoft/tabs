import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterAll, beforeAll, beforeEach, expect, test } from 'vitest'
import { contentRegistry } from '../../../../renderer/src/core/registry/registry'
import { createRendererPluginContext } from '../../../../renderer/src/plugin/context'
import { initialPane } from '../../../../renderer/src/testing/domQueries'
import { renderApp } from '../../../../renderer/src/testing/renderApp'
import { GIT_TREE_TYPE } from '../../shared/manifest'
import { gitTreeContentDef } from '../gitTreeContentDef'
import { activate as activateGitTree } from '../index'

/**
 * A git tree pane inheriting a directory from the pane it was created from.
 *
 * Driven through the real empty-pane toolbar and the real registry, so this
 * exercises the whole path — `createContentFor` → the git tree's
 * `deriveConfig` → `exposedCwdOf` → the origin type's `exposeCwd` — rather
 * than any part of it in isolation. What that path does with synthetic types
 * is covered in content/__tests__/createFrom.test.tsx; what it does with a
 * *real* pty whose live directory differs from its stale config is the
 * Electron tier's (e2e/git-tree.spec.ts), since only a real shell can `cd`.
 *
 * The stand-in origin here declares `exposeCwd` and nothing else, which is
 * precisely the point: the git tree reads a directory off a type that does not
 * exist in the shipping app and that it has never heard of.
 */

const ORIGIN_TYPE = 'cwd-bearing-origin'
const INERT_TYPE = 'inert-origin'

/** What the stand-in origin claims its directory is; a test can move it. */
let originCwd: string | undefined = '/origin/repo'

beforeAll(() => {
  activateGitTree(createRendererPluginContext(GIT_TREE_TYPE))
  contentRegistry.register({
    type: ORIGIN_TYPE,
    displayName: 'Origin',
    Component: () => null,
    exposeCwd: async () => originCwd
  })
  // A type with no `exposeCwd` at all — the shape of every content type that
  // has no directory to offer, the browser included.
  contentRegistry.register({
    type: INERT_TYPE,
    displayName: 'Inert',
    Component: () => null
  })
})

afterAll(() => {
  contentRegistry.unregister(GIT_TREE_TYPE)
  contentRegistry.unregister(ORIGIN_TYPE)
  contentRegistry.unregister(INERT_TYPE)
})

beforeEach(() => {
  originCwd = '/origin/repo'
  window.__fakeApi?.setGitTreeLog([], { root: '/origin/repo' })
  window.__fakeApi?.setGitTreeDefaultDirectory('/fallback/default')
})

/** Presses the empty pane's New git tree button and waits for the pane to appear. */
async function openGitTreeFromEmptyPane(): Promise<void> {
  const user = userEvent.setup()
  await user.click(within(initialPane()).getByTestId('empty-pane-new-git-tree-button'))
  await screen.findByTestId('git-tree')
}

test('a git tree created from a pane that exposes a directory opens on it', async () => {
  // The origin is a type the git tree has never heard of; the only thing they
  // share is the capability.
  renderApp({
    root: { id: 'origin-pane', type: ORIGIN_TYPE, config: {} },
    settings: { disabledContentTypes: [] }
  })
  const user = userEvent.setup()

  // Pressing the git tree button on this pane's own header tabs a git tree in
  // beside it, with the origin resolved from that pane.
  await user.click(within(initialPane()).getByTestId('pane-new-git-tree-button'))

  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls()).toContain('/origin/repo')
  })
  await waitFor(() => {
    expect(screen.getByTestId('git-tree-path-input')).toHaveValue('/origin/repo')
  })
  // ...and it never fell back, which is what proves the inheritance rather
  // than the default happening to be right.
  expect(window.__fakeApi?.gitTreeLogCalls()).not.toContain('/fallback/default')
})

test('an origin that exposes no directory falls back to the default, not to a blank pane', async () => {
  renderApp({
    root: { id: 'inert-pane', type: INERT_TYPE, config: {} },
    settings: { disabledContentTypes: [] }
  })
  const user = userEvent.setup()

  await user.click(within(initialPane()).getByTestId('pane-new-git-tree-button'))

  await waitFor(() => {
    expect(window.__fakeApi?.gitTreeLogCalls()).toContain('/fallback/default')
  })
  await waitFor(() => {
    expect(screen.getByTestId('git-tree-path-input')).toHaveValue('/fallback/default')
  })
})

test('an origin that exposes a directory only sometimes still degrades cleanly', async () => {
  // A live pty that has already exited answers exactly this way.
  originCwd = undefined
  renderApp({
    root: { id: 'origin-pane', type: ORIGIN_TYPE, config: {} },
    settings: { disabledContentTypes: [] }
  })
  const user = userEvent.setup()

  await user.click(within(initialPane()).getByTestId('pane-new-git-tree-button'))

  await waitFor(() => {
    expect(screen.getByTestId('git-tree-path-input')).toHaveValue('/fallback/default')
  })
})

/**
 * The case the coordinator asked to be sure of: an empty pane is the one
 * origin guaranteed to offer nothing, and the empty-pane toolbar is the only
 * creation path whose origin is *always* empty.
 */
test('a git tree created from an empty pane falls through to its default directory', async () => {
  renderApp({ settings: { disabledContentTypes: [] } })

  await openGitTreeFromEmptyPane()

  await waitFor(() => {
    expect(screen.getByTestId('git-tree-path-input')).toHaveValue('/fallback/default')
  })
  // A real pane, not an error state and not an empty path bar.
  expect(screen.queryByTestId('git-tree-empty')).not.toBeInTheDocument()
  expect(screen.getByTestId('git-tree-path-input')).not.toHaveValue('')
})

/**
 * The other direction — a terminal created *from* a git tree pane landing in
 * that repository — is deliberately **not** tested here.
 *
 * Asserting it would mean importing `terminalContentDef`, and that pulls in
 * TerminalRenderer, xterm and its CSS: exactly the import this tier exists to
 * keep out (see CLAUDE.md on the three tiers, and registerTestContent.ts). It
 * does work in jsdom, which is the trap — it passes while quietly making this
 * tier carry the dependency the tier rule is about. It lives in
 * e2e/git-tree.spec.ts instead, where a real shell can report a real
 * directory, and where the `inheritCwdOnNewPane` gate can be driven for real.
 *
 * What this file *can* cover of that direction is the half the git tree owns:
 * that it offers a directory at all for another type to read.
 */
test("the git tree's own exposeCwd reports its configured directory", async () => {
  expect(
    await gitTreeContentDef.exposeCwd?.({ id: 'p', type: GIT_TREE_TYPE, config: { cwd: '/repo' } })
  ).toBe('/repo')
  // Undefined while a fresh pane is still adopting its default, which is what
  // stops a half-initialised pane handing a bogus directory to a terminal.
  expect(
    await gitTreeContentDef.exposeCwd?.({ id: 'p', type: GIT_TREE_TYPE, config: {} })
  ).toBeUndefined()
})
