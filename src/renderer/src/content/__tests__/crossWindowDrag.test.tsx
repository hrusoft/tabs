import type {
  CrossWindowDetachResponse,
  CrossWindowInsertResponse
} from '@shared/layoutCrossWindow'
import { CROSS_WINDOW_TRANSFER_STATE_KEY } from '@shared/layoutCrossWindow'
import { createLeaf, createSplit, createTab, createTabs } from '@shared/model/factories'
import { collectLeaves, findNode } from '@shared/model/tree'
import type { ContentNode, LeafContent, SplitContent, TabsContent } from '@shared/model/types'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { registerPaneHandle } from '../../core/registry/paneHandles'
import { layoutSnapshotOf, useLayoutStore } from '../../core/store/layoutStore'
import { installCrossWindowDrag } from '../crossWindowDrag'

// `.tsx` despite holding no JSX: the vitest project is selected by extension,
// and the layout store reads window.api at module-eval time, which only the
// components tier's setup installs.

/** The docked root: one top-level tab whose content is a nested group of two leaves. */
function seedNestedGroup(): { nested: ContentNode; leaves: LeafContent[]; bystander: LeafContent } {
  const a = createLeaf('stub', { name: 'a' })
  const b = createLeaf('stub', { name: 'b' })
  const nested = createTabs([createTab('A', a), createTab('B', b)])
  const bystander = createLeaf('stub', { name: 'bystander' })
  const root = createTabs([createTab('Group', nested), createTab('Other', bystander)])
  useLayoutStore.setState({ root, activePaneId: bystander.id, floating: [] })
  return { nested, leaves: [a, b], bystander }
}

/** Registers a handle for `id` whose extension declares both cross-window capabilities. */
function registerMovable(id: string, transferState: string | undefined) {
  const undo = vi.fn()
  const prepare = vi.fn(() => undo)
  const capture = vi.fn(() => transferState)
  const unregister = registerPaneHandle(id, {
    extension: { prepareCrossWindowDetach: prepare, captureTransferState: capture }
  })
  return { undo, prepare, capture, unregister }
}

function lastDetachResponse(): CrossWindowDetachResponse {
  const responses = (window.__fakeApi?.crossWindowSent() ?? []).filter(
    (message): message is CrossWindowDetachResponse => message.type === 'detach-response'
  )
  const last = responses[responses.length - 1]
  if (!last) throw new Error('no detach response was sent')
  return last
}

/** Delivers a detach request exactly as main's `requestDetach` would. */
function requestDetach(requestId: string, paneId: string): void {
  window.__fakeApi?.emitCrossWindow({
    type: 'detach-request',
    requestId,
    subject: { kind: 'pane', paneId }
  })
}

describe('installing the cross-window protocol', () => {
  it('tells main it is listening, once it is', () => {
    // Main treats a window as able to answer only after this: a loaded page
    // can still be one whose App has not subscribed yet.
    window.__fakeApi?.reset()
    const uninstall = installCrossWindowDrag()
    expect(window.__fakeApi?.crossWindowSent()).toEqual([{ type: 'ready' }])
    uninstall()
  })
})

describe('answering a cross-window detach request', () => {
  let uninstall: () => void
  const unregisters: (() => void)[] = []

  beforeEach(() => {
    window.__fakeApi?.reset()
    uninstall = installCrossWindowDrag()
  })

  afterEach(() => {
    uninstall()
    for (const unregister of unregisters.splice(0)) unregister()
    vi.restoreAllMocks()
  })

  it('primes and captures every leaf under a dragged group, not only a bare-leaf subject', () => {
    // Priming only a bare-leaf subject left every nested terminal on the
    // ordinary unmount path, whose grace-period disposal killed its pty.
    const { nested, leaves } = seedNestedGroup()
    const handles = leaves.map((leaf) => registerMovable(leaf.id, `state-of-${leaf.config.name}`))
    unregisters.push(...handles.map((handle) => handle.unregister))

    requestDetach('r1', nested.id)

    for (const handle of handles) {
      expect(handle.prepare).toHaveBeenCalledTimes(1)
      expect(handle.capture).toHaveBeenCalledTimes(1)
      expect(handle.undo).not.toHaveBeenCalled()
    }
    const response = lastDetachResponse()
    expect(response.ok).toBe(true)
    if (!response.ok || response.content.kind !== 'pane') throw new Error('unexpected response')
    // Each leaf travels with its own snapshot, under the shared key.
    const travelled = collectLeaves(response.content.node)
    expect(travelled.map((leaf) => leaf.config[CROSS_WINDOW_TRANSFER_STATE_KEY])).toEqual([
      'state-of-a',
      'state-of-b'
    ])
    // And the group really left this window's tree.
    expect(findNode(useLayoutStore.getState().root, nested.id)).toBeNull()
  })

  it('stamps only the leaves that had something to carry', () => {
    const { nested, leaves } = seedNestedGroup()
    const [a, b] = leaves as [LeafContent, LeafContent]
    unregisters.push(registerMovable(a.id, 'only-a').unregister)
    unregisters.push(registerMovable(b.id, undefined).unregister)

    requestDetach('r2', nested.id)

    const response = lastDetachResponse()
    if (!response.ok || response.content.kind !== 'pane') throw new Error('unexpected response')
    const travelled = collectLeaves(response.content.node)
    expect(travelled[0]?.config[CROSS_WINDOW_TRANSFER_STATE_KEY]).toBe('only-a')
    expect(travelled[1]?.config).not.toHaveProperty(CROSS_WINDOW_TRANSFER_STATE_KEY)
  })

  it('undoes every priming when the detach itself is refused', () => {
    // The docked root can never be detached, so every leaf's priming has to
    // be walked back, or each pane leaks its pty on its next real close.
    const { leaves } = seedNestedGroup()
    const handles = leaves.map((leaf) => registerMovable(leaf.id, undefined))
    unregisters.push(...handles.map((handle) => handle.unregister))
    const rootId = useLayoutStore.getState().root.id

    requestDetach('r3', rootId)

    expect(lastDetachResponse().ok).toBe(false)
    for (const handle of handles) {
      expect(handle.prepare).toHaveBeenCalledTimes(1)
      expect(handle.undo).toHaveBeenCalledTimes(1)
    }
  })

  it('reports a detach that changed the tree even when a store subscriber then throws', () => {
    // Zustand commits before it notifies, so a throwing subscriber unwound
    // the action after the pane had already left — and the reply said
    // refused, leaving the content in no window at all.
    const { nested } = seedNestedGroup()
    const unsubscribe = useLayoutStore.subscribe(() => {
      throw new Error('a subscriber that throws')
    })
    vi.spyOn(console, 'error').mockImplementation(() => {})
    try {
      requestDetach('r5', nested.id)
    } finally {
      unsubscribe()
    }

    expect(findNode(useLayoutStore.getState().root, nested.id)).toBeNull()
    const response = lastDetachResponse()
    expect(response.ok).toBe(true)
    if (!response.ok || response.content.kind !== 'pane') throw new Error('unexpected response')
    expect(response.content.node.id).toBe(nested.id)
  })

  it('reports an insert that changed the tree even when a store subscriber then throws', () => {
    // The mirror case: a refused reply rolls the content back into the
    // source while it also stays here — the same ids live in two windows.
    const { bystander } = seedNestedGroup()
    const incoming = createLeaf('stub', { name: 'incoming' })
    const unsubscribe = useLayoutStore.subscribe(() => {
      throw new Error('a subscriber that throws')
    })
    vi.spyOn(console, 'error').mockImplementation(() => {})
    try {
      window.__fakeApi?.emitCrossWindow({
        type: 'insert-request',
        requestId: 'r6',
        content: { kind: 'pane', node: incoming },
        placement: { kind: 'dock', target: { kind: 'dock', targetId: bystander.id, zone: 'left' } }
      })
    } finally {
      unsubscribe()
    }

    expect(findNode(useLayoutStore.getState().root, incoming.id)).not.toBeNull()
    const response = (window.__fakeApi?.crossWindowSent() ?? []).find(
      (message): message is CrossWindowInsertResponse => message.type === 'insert-response'
    )
    expect(response?.ok).toBe(true)
  })

  it("lets a window's only tab leave, and a rollback puts its content back", () => {
    // Its departure consumes the whole tree; the detach used to refuse that
    // after another window had already previewed the drop.
    const only = createLeaf('stub', { name: 'only' })
    const onlyTab = createTab('Only', only)
    const root = createTabs([onlyTab])
    useLayoutStore.setState({ root, activePaneId: only.id, floating: [] })

    window.__fakeApi?.emitCrossWindow({
      type: 'detach-request',
      requestId: 'r7',
      subject: { kind: 'tab', tabId: onlyTab.id, sourceGroupId: root.id }
    })

    const response = lastDetachResponse()
    if (!response.ok || response.content.kind !== 'tab') throw new Error('unexpected response')
    expect(response.content.tab.content.id).toBe(only.id)
    const left = useLayoutStore.getState().root
    expect(findNode(left, only.id)).toBeNull()
    expect(collectLeaves(left).map((leaf) => leaf.type)).toEqual(['empty'])

    window.__fakeApi?.emitCrossWindow({
      type: 'insert-request',
      requestId: 'r8',
      content: response.content,
      placement: { kind: 'anchor', anchor: response.anchor }
    })
    const restored = useLayoutStore.getState().root
    expect(collectLeaves(restored).map((leaf) => leaf.id)).toEqual([only.id])
    expect(restored.tabs.map((tab) => tab.title)).toEqual(['Only'])
  })

  it.each([
    ['tab', (moved: ReturnType<typeof createTab>) => ({ kind: 'tab' as const, tabId: moved.id })],
    [
      'pane',
      (moved: ReturnType<typeof createTab>) => ({ kind: 'pane' as const, paneId: moved.content.id })
    ]
  ])('rolls a top-level %s back into its own slot, under its own title', (_kind, subjectOf) => {
    // Detaching one of two top-level tabs collapses the root, and the rebuilt
    // group has a fresh id the anchor could not find — the rollback appended
    // the tab at the end under a derived title.
    const moved = createTab('My renamed tab', createLeaf('stub'))
    const other = createTab('Other', createLeaf('stub'))
    const root = createTabs([moved, other])
    useLayoutStore.setState({ root, activePaneId: moved.content.id, floating: [] })
    const subject = subjectOf(moved)

    window.__fakeApi?.emitCrossWindow({
      type: 'detach-request',
      requestId: 'r12',
      subject: subject.kind === 'tab' ? { ...subject, sourceGroupId: root.id } : subject
    })
    const response = lastDetachResponse()
    if (!response.ok) throw new Error('unexpected response')
    window.__fakeApi?.emitCrossWindow({
      type: 'insert-request',
      requestId: 'r13',
      content: response.content,
      placement: { kind: 'anchor', anchor: response.anchor }
    })

    const restored = useLayoutStore.getState().root
    expect(restored.tabs.map((tab) => tab.title)).toEqual(['My renamed tab', 'Other'])
    expect(restored.tabs.map((tab) => tab.content.id)).toEqual([moved.content.id, other.content.id])
  })

  it('refuses an edge dock against the docked root, whatever asked for it', () => {
    // The resolver never offers this target; the store refuses it anyway, as
    // dockPane and dockTab do — otherwise the whole window becomes a split
    // rewrapped under a stranger tab.
    seedNestedGroup()
    const root = useLayoutStore.getState().root
    window.__fakeApi?.emitCrossWindow({
      type: 'insert-request',
      requestId: 'r9',
      content: { kind: 'pane', node: createLeaf('stub') },
      placement: { kind: 'dock', target: { kind: 'dock', targetId: root.id, zone: 'left' } }
    })

    expect(useLayoutStore.getState().root).toBe(root)
    const response = (window.__fakeApi?.crossWindowSent() ?? []).find(
      (message): message is CrossWindowInsertResponse => message.type === 'insert-response'
    )
    expect(response?.ok).toBe(false)
  })

  it.each([
    ['tab', (other: ReturnType<typeof createTab>) => ({ kind: 'tab' as const, tabId: other.id })],
    [
      'pane',
      (other: ReturnType<typeof createTab>) => ({ kind: 'pane' as const, paneId: other.content.id })
    ]
  ])('keeps the surviving root tab its own title when a %s leaves', (_kind, subjectOf) => {
    // Detaching one of two top-level tabs collapses the root group, and its
    // rebuilt wrapper was retitled from the content — a title the user set
    // by hand was lost, where the in-window close of that tab keeps it.
    const kept = createTab('Server (renamed)', createLeaf('stub'))
    const other = createTab('Other', createLeaf('stub'))
    const root = createTabs([kept, other])
    useLayoutStore.setState({ root, activePaneId: kept.content.id, floating: [] })
    const subject = subjectOf(other)

    window.__fakeApi?.emitCrossWindow({
      type: 'detach-request',
      requestId: 'r10',
      subject: subject.kind === 'tab' ? { ...subject, sourceGroupId: root.id } : subject
    })

    expect(lastDetachResponse().ok).toBe(true)
    expect(useLayoutStore.getState().root.tabs.map((tab) => tab.title)).toEqual([
      'Server (renamed)'
    ])
  })

  it('walks back the leaves it already primed when priming a later one throws', () => {
    // A primed pane skips its dispose on its next real close, so one left
    // primed by a detach that never happened leaks its pty.
    const { nested, leaves } = seedNestedGroup()
    const [a, b] = leaves as [LeafContent, LeafContent]
    const first = registerMovable(a.id, 'state-of-a')
    unregisters.push(first.unregister)
    unregisters.push(
      registerPaneHandle(b.id, {
        extension: {
          captureTransferState: () => {
            throw new Error('capture failed')
          }
        }
      })
    )
    vi.spyOn(console, 'error').mockImplementation(() => {})

    requestDetach('r11', nested.id)

    expect(first.prepare).toHaveBeenCalledTimes(1)
    expect(first.undo).toHaveBeenCalledTimes(1)
    expect(lastDetachResponse().ok).toBe(false)
    expect(findNode(useLayoutStore.getState().root, nested.id)).not.toBeNull()
  })

  /** Detaches `tabId` and replays the rollback insert main sends when the destination refuses. */
  function detachThenRollBack(tabId: string, groupId: string): void {
    window.__fakeApi?.emitCrossWindow({
      type: 'detach-request',
      requestId: 'rb-detach',
      subject: { kind: 'tab', tabId, sourceGroupId: groupId }
    })
    const response = lastDetachResponse()
    if (!response.ok) throw new Error('the detach was refused')
    window.__fakeApi?.emitCrossWindow({
      type: 'insert-request',
      requestId: 'rb-insert',
      content: response.content,
      placement: { kind: 'anchor', anchor: response.anchor }
    })
  }

  it('rolls a tab back into the nested two-tab group it left, under its own title', () => {
    // Its departure collapsed the group into the other tab's bare content, so
    // the anchor's group and neighbour ids were gone and the tab came back as
    // a new top-level tab with a derived title.
    const [left, x, y] = [createLeaf('stub'), createLeaf('stub'), createLeaf('stub')]
    const moved = createTab('Renamed X', x)
    const group = createTabs([moved, createTab('Kept', y)])
    const root = createTabs([createTab('Top', createSplit('horizontal', [left, group]))])
    useLayoutStore.setState({ root, activePaneId: x.id, floating: [] })

    detachThenRollBack(moved.id, group.id)

    const after = useLayoutStore.getState().root
    expect(after.tabs.map((tab) => tab.title)).toEqual(['Top'])
    const split = after.tabs[0]!.content as SplitContent
    const rebuilt = split.children[1] as TabsContent
    expect(rebuilt.id).toBe(group.id)
    expect(rebuilt.tabs.map((tab) => tab.title)).toEqual(['Renamed X', 'Kept'])
    expect(rebuilt.tabs.map((tab) => tab.content.id)).toEqual([x.id, y.id])
  })

  it("rolls a nested group's only tab back into that group, where it sat", () => {
    const [left, x] = [createLeaf('stub'), createLeaf('stub')]
    const moved = createTab('Only', x)
    const group = createTabs([moved])
    const root = createTabs([createTab('Top', createSplit('horizontal', [left, group]))])
    useLayoutStore.setState({ root, activePaneId: x.id, floating: [] })

    detachThenRollBack(moved.id, group.id)

    const split = useLayoutStore.getState().root.tabs[0]!.content as SplitContent
    expect(split.children.map((child) => child.id)).toEqual([left.id, group.id])
    expect((split.children[1] as TabsContent).tabs.map((tab) => tab.title)).toEqual(['Only'])
  })

  it.each([
    [
      'tab',
      (group: TabsContent) => ({
        kind: 'tab' as const,
        tabId: group.tabs[0]!.id,
        sourceGroupId: group.id
      })
    ],
    ['pane', (group: TabsContent) => ({ kind: 'pane' as const, paneId: group.tabs[0]!.content.id })]
  ])(
    'puts a whole window back exactly when its only content, wrapped in a group, returns as a %s',
    (_kind, subjectOf) => {
      // "Wrap in tab group" on a window's only pane: root → G → X. Taking X took
      // everything, but no tree op said so (the root kept a tab holding an
      // emptied group), so the rollback rebuilt the old root nested inside the
      // new one — an extra tab strip, and a placeholder tab beside it.
      const x = createLeaf('stub')
      const group = createTabs([createTab('X', x)])
      const root = createTabs([createTab('Top', group)])
      useLayoutStore.setState({ root, activePaneId: x.id, floating: [] })

      window.__fakeApi?.emitCrossWindow({
        type: 'detach-request',
        requestId: 'whole-detach',
        subject: subjectOf(group)
      })
      const response = lastDetachResponse()
      if (!response.ok) throw new Error('the detach was refused')
      expect(collectLeaves(useLayoutStore.getState().root).map((leaf) => leaf.type)).toEqual([
        'empty'
      ])
      window.__fakeApi?.emitCrossWindow({
        type: 'insert-request',
        requestId: 'whole-insert',
        content: response.content,
        placement: { kind: 'anchor', anchor: response.anchor }
      })

      const after = useLayoutStore.getState().root
      expect(after.id).toBe(root.id)
      expect(after.tabs.map((tab) => tab.title)).toEqual(['Top'])
      const restored = after.tabs[0]!.content as TabsContent
      expect(restored.id).toBe(group.id)
      expect(restored.tabs.map((tab) => [tab.title, tab.content.id])).toEqual([['X', x.id]])
    }
  )

  it("keeps the user's own empty tab when a rollback lands beside it", () => {
    // A window holding one empty leaf after a detach looked exactly like the
    // placeholder a detach of everything leaves, so the rollback rebuilt the
    // window around the returning tab and the user's empty tab was gone.
    const notes = createTab('Notes', createLeaf('empty'))
    const moved = createTab('B', createLeaf('stub'))
    const root = createTabs([notes, moved])
    useLayoutStore.setState({ root, activePaneId: moved.content.id, floating: [] })

    detachThenRollBack(moved.id, root.id)

    const after = useLayoutStore.getState().root
    expect(after.tabs.map((tab) => tab.title)).toEqual(['Notes', 'B'])
    expect(after.tabs.map((tab) => tab.content.id)).toEqual([notes.content.id, moved.content.id])
  })

  it('never persists the transfer state it carries', () => {
    // The store keeps the key until the destination's renderer consumes it;
    // nothing persisted may carry a terminal's scrollback.
    const carrying = createLeaf('stub', { [CROSS_WINDOW_TRANSFER_STATE_KEY]: 'scrollback…' })
    const plain = createLeaf('stub')
    const root = createTabs([createTab('Carrying', carrying), createTab('Plain', plain)])
    useLayoutStore.setState({ root, activePaneId: plain.id, floating: [] })

    const snapshot = layoutSnapshotOf(useLayoutStore.getState())

    const persisted = collectLeaves(snapshot.root).find((leaf) => leaf.id === carrying.id)
    expect(persisted?.config).not.toHaveProperty(CROSS_WINDOW_TRANSFER_STATE_KEY)
    // Still there for the renderer that will consume it.
    const live = findNode(useLayoutStore.getState().root, carrying.id) as LeafContent
    expect(live.config[CROSS_WINDOW_TRANSFER_STATE_KEY]).toBe('scrollback…')
    // A tree carrying none comes back by reference.
    useLayoutStore.setState({ root: createTabs([createTab('Plain', plain)]) })
    const untouched = useLayoutStore.getState().root
    expect(layoutSnapshotOf(useLayoutStore.getState()).root).toBe(untouched)
  })
})
