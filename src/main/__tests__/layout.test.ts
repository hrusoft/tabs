import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { LAYOUT_VERSION } from '../../shared/layout'
import { createLeaf, createSplit, createTab, createTabs } from '../../shared/model/factories'
import type { LeafContent, TabsContent } from '../../shared/model/types'
import { DEFAULT_LAYOUT, loadLayout, saveLayout, withPatchedLeafConfigs } from '../layout'

describe('loadLayout', () => {
  it('falls back to the default layout when the file is missing', () => {
    const layout = loadLayout({
      path: '/nonexistent/layout.json',
      readFile: () => {
        throw new Error('ENOENT')
      }
    })
    expect(layout).toEqual(DEFAULT_LAYOUT)
  })

  it('falls back to the default layout when the file has corrupt JSON', () => {
    const layout = loadLayout({ path: '/fake/layout.json', readFile: () => 'not json' })
    expect(layout).toEqual(DEFAULT_LAYOUT)
  })

  it('falls back to the default layout on a version mismatch', () => {
    const layout = loadLayout({
      path: '/fake/layout.json',
      readFile: () =>
        JSON.stringify({
          version: LAYOUT_VERSION + 1,
          root: createLeaf('terminal'),
          activePaneId: 'x'
        })
    })
    expect(layout).toEqual(DEFAULT_LAYOUT)
  })

  it('falls back to the default layout when root is not a plausible node', () => {
    const layout = loadLayout({
      path: '/fake/layout.json',
      readFile: () => JSON.stringify({ version: LAYOUT_VERSION, root: null, activePaneId: 'x' })
    })
    expect(layout).toEqual(DEFAULT_LAYOUT)
  })

  it('round-trips a valid layout through saveLayout, wrapped as a top-level tab', () => {
    const root = createLeaf('terminal', { cwd: '~/code' })
    let stored = ''
    saveLayout(
      { version: LAYOUT_VERSION, root, activePaneId: root.id },
      { path: '/fake/layout.json', writeFile: (_path, data) => (stored = data) }
    )
    const layout = loadLayout({ path: '/fake/layout.json', readFile: () => stored })
    // The docked root is always a tab group (see ensureTabsRoot) — a bare
    // leaf saved directly, as every layout was before this invariant
    // existed, comes back wrapped as the sole tab of a fresh group, the
    // leaf itself untouched and still the active pane.
    const wrappedRoot = layout.root as TabsContent
    expect(wrappedRoot.type).toBe('tabs')
    expect(wrappedRoot.tabs).toHaveLength(1)
    expect(wrappedRoot.tabs[0]!.content).toEqual(root)
    expect(layout.activePaneId).toBe(root.id)
    expect(layout.floating).toEqual([])
  })

  it('loads a version 1 file written before floating panes existed', () => {
    const root = createLeaf('terminal')
    const layout = loadLayout({
      path: '/fake/layout.json',
      readFile: () => JSON.stringify({ version: LAYOUT_VERSION, root, activePaneId: root.id })
    })
    expect(layout.floating).toEqual([])
    const wrappedRoot = layout.root as TabsContent
    expect(wrappedRoot.tabs[0]!.content).toEqual(root)
  })

  it('keeps a floating pane, normalizing its content', () => {
    const root = createLeaf('empty')
    const tab = createTab('Shell', createLeaf('terminal'))
    const floating = [
      {
        id: 'float-1',
        content: { ...createTabs([tab]), activeTabId: 'stale-id' },
        rect: { x: 10, y: 20, width: 400, height: 300 },
        anchor: { kind: 'root' }
      }
    ]
    const layout = loadLayout({
      path: '/fake/layout.json',
      readFile: () =>
        JSON.stringify({ version: LAYOUT_VERSION, root, activePaneId: root.id, floating })
    })
    const loaded = layout.floating ?? []
    expect(loaded).toHaveLength(1)
    expect((loaded[0]!.content as TabsContent).activeTabId).toBe(tab.id)
    expect(loaded[0]!.rect).toEqual({ x: 10, y: 20, width: 400, height: 300 })
  })

  it('drops a floating entry whose content is not a plausible node', () => {
    const root = createLeaf('empty')
    const layout = loadLayout({
      path: '/fake/layout.json',
      readFile: () =>
        JSON.stringify({
          version: LAYOUT_VERSION,
          root,
          activePaneId: root.id,
          floating: [{ id: 'float-1', content: null, rect: null, anchor: null }]
        })
    })
    expect(layout.floating).toEqual([])
  })

  it('round-trips a custom tab title and pane title override untouched', () => {
    const leaf = { ...createLeaf('terminal', { cwd: '~' }), title: 'My server' }
    const tab = createTab('Deploy', leaf)
    const root = createTabs([tab])
    let stored = ''
    saveLayout(
      { version: LAYOUT_VERSION, root, activePaneId: tab.content.id },
      { path: '/fake/layout.json', writeFile: (_path, data) => (stored = data) }
    )
    const layout = loadLayout({ path: '/fake/layout.json', readFile: () => stored })
    const loadedRoot = layout.root as TabsContent
    expect(loadedRoot.tabs[0]!.title).toBe('Deploy')
    expect(loadedRoot.tabs[0]!.content).toEqual(leaf)
  })

  it('normalizes a tree with a dangling activeTabId on load', () => {
    const tab = createTab('Shell', createLeaf('terminal'))
    const group: TabsContent = { ...createTabs([tab]), activeTabId: 'stale-id' }
    const layout = loadLayout({
      path: '/fake/layout.json',
      readFile: () =>
        JSON.stringify({ version: LAYOUT_VERSION, root: group, activePaneId: group.id })
    })
    const root = layout.root as TabsContent
    expect(root.activeTabId).toBe(tab.id)
  })
})

describe('withPatchedLeafConfigs', () => {
  it("replaces a leaf's cwd with its mapped entry", () => {
    const terminal = createLeaf('terminal', { cwd: '~' })
    const layout = { version: 1 as const, root: terminal, activePaneId: terminal.id }

    const result = withPatchedLeafConfigs(
      layout,
      new Map([[terminal.id, { cwd: '/tmp/live-dir' }]])
    )

    expect((result.root as LeafContent).config.cwd).toBe('/tmp/live-dir')
  })

  it('merges the patch over the config keys it does not name', () => {
    // The transform knows no key of any content type — a patch says what to
    // write, and everything else the pane was carrying survives.
    const leaf = createLeaf('terminal', { cwd: '~', shell: '/bin/zsh' })
    const layout = { version: 1 as const, root: leaf, activePaneId: leaf.id }

    const result = withPatchedLeafConfigs(layout, new Map([[leaf.id, { cwd: '/tmp/live' }]]))

    expect((result.root as LeafContent).config).toEqual({ cwd: '/tmp/live', shell: '/bin/zsh' })
  })

  it('leaves a leaf with no matching entry untouched', () => {
    const terminal = createLeaf('terminal', { cwd: '~' })
    const layout = { version: 1 as const, root: terminal, activePaneId: terminal.id }

    const result = withPatchedLeafConfigs(layout, new Map())

    expect(result).toBe(layout)
  })

  it('only touches the leaves present in the map, across a split', () => {
    const a = createLeaf('terminal', { cwd: '~' })
    const b = createLeaf('terminal', { cwd: '~' })
    const root = createSplit('horizontal', [a, b])
    const layout = { version: 1 as const, root, activePaneId: a.id }

    const result = withPatchedLeafConfigs(layout, new Map([[a.id, { cwd: '/tmp/only-a' }]]))
    const resultRoot = result.root as ReturnType<typeof createSplit>

    expect((resultRoot.children[0] as LeafContent).config.cwd).toBe('/tmp/only-a')
    expect(resultRoot.children[1]).toBe(b)
  })

  it('patches a leaf inside a floating pane', () => {
    const docked = createLeaf('empty')
    const floated = createLeaf('terminal', { cwd: '~' })
    const layout = {
      version: 1 as const,
      root: docked,
      activePaneId: docked.id,
      floating: [
        {
          id: 'float-1',
          content: floated,
          rect: { x: 0, y: 0, width: 400, height: 300 },
          anchor: { kind: 'root' as const }
        }
      ]
    }

    const result = withPatchedLeafConfigs(
      layout,
      new Map([[floated.id, { cwd: '/tmp/floating-dir' }]])
    )

    const refreshed = result.floating ?? []
    expect((refreshed[0]!.content as LeafContent).config.cwd).toBe('/tmp/floating-dir')
    expect(result.root).toBe(docked)
  })

  it('returns the same layout when no floating leaf matched either', () => {
    const docked = createLeaf('empty')
    const floated = createLeaf('terminal', { cwd: '~' })
    const layout = {
      version: 1 as const,
      root: docked,
      activePaneId: docked.id,
      floating: [
        {
          id: 'float-1',
          content: floated,
          rect: { x: 0, y: 0, width: 400, height: 300 },
          anchor: { kind: 'root' as const }
        }
      ]
    }

    expect(withPatchedLeafConfigs(layout, new Map([['someone-else', { cwd: '/tmp/x' }]]))).toBe(
      layout
    )
  })
})

describe('saveLayout', () => {
  it('writes the layout as JSON to the given path', () => {
    const root = createLeaf('empty')
    let written: { path: string; data: string } | undefined
    saveLayout(
      { version: LAYOUT_VERSION, root, activePaneId: root.id },
      {
        path: '/fake/layout.json',
        writeFile: (path, data) => {
          written = { path, data }
        }
      }
    )
    expect(written).not.toBeUndefined()
    expect(written?.path).toBe('/fake/layout.json')
    expect(JSON.parse(written?.data ?? '')).toEqual({
      version: LAYOUT_VERSION,
      root,
      activePaneId: root.id
    })
  })

  // saveLayout runs inside a synchronous ipcMain.on listener, so a throw here
  // escapes into Electron's C++ dispatch and becomes a native error dialog
  // rather than a lost save — see src/main/persist.ts.
  it('reports a failed write instead of throwing out of the save', () => {
    const root = createLeaf('empty')
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() =>
      saveLayout(
        { version: LAYOUT_VERSION, root, activePaneId: root.id },
        {
          path: '/fake/layout.json',
          writeFile: () => {
            throw new Error('ENOENT: no such file or directory')
          }
        }
      )
    ).not.toThrow()
    expect(logged).toHaveBeenCalled()
    logged.mockRestore()
  })

  it('creates a missing parent directory rather than failing the write', () => {
    const dir = mkdtempSync(join(tmpdir(), 'tabs-layout-test-'))
    const target = join(dir, 'vanished', 'layout.json')
    const root = createLeaf('empty')
    // No writeFile override: this is the real default writer, the one that
    // runs when the userData directory has gone missing under a live app.
    saveLayout({ version: LAYOUT_VERSION, root, activePaneId: root.id }, { path: target })
    expect(JSON.parse(readFileSync(target, 'utf-8'))).toEqual({
      version: LAYOUT_VERSION,
      root,
      activePaneId: root.id
    })
    rmSync(dir, { recursive: true, force: true })
  })
})
