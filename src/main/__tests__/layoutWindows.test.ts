import {
  createLeaf,
  createSplit,
  createTab,
  createTabs
} from '@tabs/plugin-sdk/shared/model/factories'
import type { ContentNode } from '@tabs/plugin-sdk/shared/model/types'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { IpcChannel } from '../../shared/ipc'
import type { LayoutSnapshot } from '../../shared/layout'
import { LAYOUT_VERSION } from '../../shared/layout'

// The window lifecycle rules in layout.ts — which closes drop a layout,
// which keep it, when a window's panes are reported discarded, and what main
// can answer from its copy of each window's layout. The e2e specs cover the
// same rules end to end, but only through a real app, and the close
// confirmation's pane list is invisible there (the dialog is skipped under
// E2E_HIDDEN before it reads the list).

const handlers = new Map<string, (...args: unknown[]) => unknown>()

vi.mock('../ipcListeners', () => ({
  registerSyncGetter: (channel: string, handler: (...args: unknown[]) => unknown) =>
    handlers.set(channel, handler),
  onRendererMessage: (channel: string, handler: (...args: unknown[]) => unknown) =>
    handlers.set(channel, handler)
}))
// Persistence off: nothing is read from or written to disk.
vi.mock('../settings', () => ({ getSettings: () => ({ persistLayoutOnExit: false }) }))

type CloseListener = (windowId: string, remaining: number) => void

function snapshot(root: ContentNode, floating: ContentNode[] = []): LayoutSnapshot {
  return {
    version: LAYOUT_VERSION,
    root: createTabs([createTab('Tab', root)]),
    activePaneId: root.id,
    floating: floating.map((content, index) => ({
      id: `float-${index}`,
      content,
      rect: { x: 0, y: 0, width: 300, height: 200 },
      anchor: { kind: 'root' as const }
    }))
  }
}

/** A fresh layout module, registered against fake windows whose ids stand in for their WebContents. */
async function setUp(live: string[]) {
  vi.resetModules()
  handlers.clear()
  const layout = await import('../layout')
  const liveIds = new Set(live)
  const closeListeners: CloseListener[] = []
  const discarded = vi.fn()
  layout.registerLayoutIpc({
    resolveWindowId: (webContents) => webContents as unknown as string,
    onWindowClosed: (listener) => {
      closeListeners.push(listener)
      return () => {}
    },
    liveWindowIds: () => liveIds,
    onWindowsDiscarded: discarded
  })
  const getSync = (windowId: string) =>
    handlers.get(IpcChannel.layoutGetSync)?.({ sender: windowId }) as LayoutSnapshot
  const set = (windowId: string, layoutSnapshot: LayoutSnapshot) =>
    handlers.get(IpcChannel.layoutSet)?.({ sender: windowId }, layoutSnapshot)
  const close = (windowId: string) => {
    liveIds.delete(windowId)
    for (const listener of closeListeners) listener(windowId, liveIds.size)
  }
  const open = (windowId: string) => {
    liveIds.add(windowId)
    return getSync(windowId)
  }
  return { layout, getSync, set, close, open, discarded }
}

describe("main's per-window layouts", () => {
  beforeEach(() => {
    handlers.clear()
  })

  it('lists every leaf of a window, docked and floating, for the close confirmation to ask about', async () => {
    const { layout, set } = await setUp(['A', 'B'])
    const [left, right, floated] = [createLeaf('stub'), createLeaf('stub'), createLeaf('stub')]
    set('A', snapshot(createSplit('horizontal', [left, right]), [floated]))
    set('B', snapshot(createLeaf('stub')))

    expect(layout.paneIdsOfWindow('A').sort()).toEqual([left.id, right.id, floated.id].sort())
    expect(layout.paneIdsOfWindow('nowhere')).toEqual([])
  })

  it('finds the live window whose layout holds a pane, floating ones included', async () => {
    const { layout, set, close } = await setUp(['A', 'B'])
    const [inA, floatedInB] = [createLeaf('stub'), createLeaf('stub')]
    set('A', snapshot(inA))
    set('B', snapshot(createLeaf('stub'), [floatedInB]))

    expect(layout.windowHoldingPane(inA.id)).toBe('A')
    expect(layout.windowHoldingPane(floatedInB.id)).toBe('B')
    close('B')
    expect(layout.windowHoldingPane(floatedInB.id)).toBeUndefined()
  })

  it('drops a window closed beside another, and reports its panes discarded', async () => {
    const { layout, getSync, close, discarded } = await setUp(['A', 'B'])
    getSync('A')
    getSync('B')

    close('B')

    expect(layout.restorableWindowIds()).toEqual(['A'])
    expect(discarded).toHaveBeenCalledTimes(1)
  })

  it("keeps the last window's layout, but not its panes, when it closes", async () => {
    // A reactivate brings the layout back on fresh content; the panes end
    // like any closed window's, so nothing keeps running unseen.
    const { layout, getSync, close, discarded } = await setUp(['A'])
    getSync('A')

    close('A')

    expect(layout.restorableWindowIds()).toEqual(['A'])
    expect(discarded).toHaveBeenCalledTimes(1)
  })

  it('ignores a cross-window snapshot for a window that closed during the round trip', async () => {
    const { layout, getSync, close } = await setUp(['A', 'B'])
    getSync('A')
    getSync('B')
    close('B')

    layout.applyExternalSnapshot('B', snapshot(createLeaf('stub')))

    expect(layout.restorableWindowIds()).toEqual(['A'])
  })

  it('purges a kept window a fresh one replaces, reporting its panes discarded', async () => {
    const { layout, getSync, close, open, discarded } = await setUp(['A'])
    getSync('A')
    close('A')

    open('C')

    expect(layout.restorableWindowIds()).toEqual(['C'])
    // Once for the close, once for the purge.
    expect(discarded).toHaveBeenCalledTimes(2)
  })

  it('gives each window its own default layout, repeated reads the same object', async () => {
    const { getSync } = await setUp(['A', 'B'])

    const first = getSync('A')
    expect(getSync('A')).toBe(first)
    expect(getSync('B').root.id).not.toBe(first.root.id)
  })
})
