import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { LAYOUT_VERSION } from '../../shared/layout'
import { createLeaf, createSplit, createTab, createTabs } from '../../shared/model/factories'
import type { LeafContent, TabsContent } from '../../shared/model/types'
import { loadLayoutFile, saveLayoutFile, withPatchedLeafConfigs } from '../layout'

/** `loadLayoutFile` over literal file content, no filesystem. */
function load(content: string) {
  return loadLayoutFile({ path: '/fake/layout.json', readFile: () => content })
}

describe('loadLayoutFile', () => {
  it('reads nothing from a missing file', () => {
    const windows = loadLayoutFile({
      path: '/nonexistent/layout.json',
      readFile: () => {
        throw new Error('ENOENT')
      }
    })
    expect(windows).toEqual([])
  })

  it('reads nothing from corrupt JSON', () => {
    expect(load('not json')).toEqual([])
  })

  describe('a file from before multi-window support (one bare snapshot)', () => {
    it('becomes one window, its root wrapped as a top-level tab', () => {
      const root = createLeaf('terminal', { cwd: '~/code' })
      const windows = load(JSON.stringify({ version: LAYOUT_VERSION, root, activePaneId: root.id }))

      expect(windows).toHaveLength(1)
      expect(typeof windows[0]!.id).toBe('string')
      // The docked root is always a tab group (see ensureTabsRoot) — a bare
      // leaf saved directly comes back wrapped as the sole tab of a fresh
      // group, the leaf itself untouched and still the active pane.
      const wrappedRoot = windows[0]!.layout.root as TabsContent
      expect(wrappedRoot.type).toBe('tabs')
      expect(wrappedRoot.tabs).toHaveLength(1)
      expect(wrappedRoot.tabs[0]!.content).toEqual(root)
      expect(windows[0]!.layout.activePaneId).toBe(root.id)
      expect(windows[0]!.layout.floating).toEqual([])
    })

    it('is dropped on a version mismatch', () => {
      const root = createLeaf('terminal')
      expect(
        load(JSON.stringify({ version: LAYOUT_VERSION + 1, root, activePaneId: root.id }))
      ).toEqual([])
    })

    it('is dropped when its root is not a plausible node', () => {
      expect(
        load(JSON.stringify({ version: LAYOUT_VERSION, root: null, activePaneId: 'x' }))
      ).toEqual([])
    })

    it('keeps a good docked root when a floating window is structurally hollow', () => {
      const root = createTabs([createTab('Shell', createLeaf('terminal'))])
      const [window] = load(
        JSON.stringify({
          version: LAYOUT_VERSION,
          root,
          activePaneId: root.id,
          floating: [{ id: 'f', content: { id: 'hollow', type: 'tabs' } }]
        })
      )
      expect(window!.layout.root).toEqual(root)
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
      const [window] = load(
        JSON.stringify({ version: LAYOUT_VERSION, root, activePaneId: root.id, floating })
      )

      const loaded = window!.layout.floating ?? []
      expect(loaded).toHaveLength(1)
      expect((loaded[0]!.content as TabsContent).activeTabId).toBe(tab.id)
      expect(loaded[0]!.rect).toEqual({ x: 10, y: 20, width: 400, height: 300 })
    })

    it('drops a floating entry whose content is not a plausible node', () => {
      const root = createLeaf('empty')
      const [window] = load(
        JSON.stringify({
          version: LAYOUT_VERSION,
          root,
          activePaneId: root.id,
          floating: [{ id: 'float-1', content: null, rect: null, anchor: null }]
        })
      )
      expect(window!.layout.floating).toEqual([])
    })

    it('normalizes a tree with a dangling activeTabId', () => {
      const tab = createTab('Shell', createLeaf('terminal'))
      const group: TabsContent = { ...createTabs([tab]), activeTabId: 'stale-id' }
      const [window] = load(
        JSON.stringify({ version: LAYOUT_VERSION, root: group, activePaneId: group.id })
      )
      expect((window!.layout.root as TabsContent).activeTabId).toBe(tab.id)
    })
  })

  describe("this build's own shape", () => {
    it('keeps every window, its id and its order', () => {
      const a = createLeaf('terminal')
      const b = createLeaf('browser')
      const windows = load(
        JSON.stringify({
          windows: [
            { id: 'w-a', layout: { version: LAYOUT_VERSION, root: a, activePaneId: a.id } },
            { id: 'w-b', layout: { version: LAYOUT_VERSION, root: b, activePaneId: b.id } }
          ]
        })
      )

      expect(windows.map((window) => window.id)).toEqual(['w-a', 'w-b'])
      expect((windows[0]!.layout.root as TabsContent).tabs[0]!.content).toEqual(a)
      expect((windows[1]!.layout.root as TabsContent).tabs[0]!.content).toEqual(b)
    })

    it('drops an entry with no string id or an unreadable layout, keeping the rest', () => {
      const good = createLeaf('terminal')
      const windows = load(
        JSON.stringify({
          windows: [
            { id: 42, layout: { version: LAYOUT_VERSION, root: good, activePaneId: good.id } },
            { id: 'bad-layout', layout: { version: LAYOUT_VERSION, root: null } },
            { id: 'good', layout: { version: LAYOUT_VERSION, root: good, activePaneId: good.id } }
          ]
        })
      )
      expect(windows.map((window) => window.id)).toEqual(['good'])
    })

    it('reads an empty window list as nothing to restore', () => {
      expect(load(JSON.stringify({ windows: [] }))).toEqual([])
    })
  })
})

describe('saveLayoutFile', () => {
  it('writes every window as JSON to the given path', () => {
    const root = createLeaf('empty')
    let written: { path: string; data: string } | undefined
    saveLayoutFile(
      [{ id: 'w-1', layout: { version: LAYOUT_VERSION, root, activePaneId: root.id } }],
      {
        path: '/fake/layout.json',
        writeFile: (path, data) => {
          written = { path, data }
        }
      }
    )
    expect(written?.path).toBe('/fake/layout.json')
    expect(JSON.parse(written?.data ?? '')).toEqual({
      windows: [{ id: 'w-1', layout: { version: LAYOUT_VERSION, root, activePaneId: root.id } }]
    })
  })

  it('round-trips a custom tab title and pane title override untouched', () => {
    const leaf = { ...createLeaf('terminal', { cwd: '~' }), title: 'My server' }
    const tab = createTab('Deploy', leaf)
    const root = createTabs([tab])
    let stored = ''
    saveLayoutFile(
      [{ id: 'w-1', layout: { version: LAYOUT_VERSION, root, activePaneId: tab.content.id } }],
      { path: '/fake/layout.json', writeFile: (_path, data) => (stored = data) }
    )
    const [window] = loadLayoutFile({ path: '/fake/layout.json', readFile: () => stored })
    const loadedRoot = window!.layout.root as TabsContent
    expect(loadedRoot.tabs[0]!.title).toBe('Deploy')
    expect(loadedRoot.tabs[0]!.content).toEqual(leaf)
  })

  // The save runs inside a synchronous ipcMain.on listener, so a throw here
  // escapes into Electron's C++ dispatch and becomes a native error dialog
  // rather than a lost save — see src/main/persist.ts.
  it('reports a failed write instead of throwing out of the save', () => {
    const root = createLeaf('empty')
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() =>
      saveLayoutFile(
        [{ id: 'w-1', layout: { version: LAYOUT_VERSION, root, activePaneId: root.id } }],
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
    saveLayoutFile(
      [{ id: 'w-1', layout: { version: LAYOUT_VERSION, root, activePaneId: root.id } }],
      {
        path: target
      }
    )
    expect(JSON.parse(readFileSync(target, 'utf-8'))).toEqual({
      windows: [{ id: 'w-1', layout: { version: LAYOUT_VERSION, root, activePaneId: root.id } }]
    })
    rmSync(dir, { recursive: true, force: true })
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
