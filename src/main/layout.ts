import { readFileSync } from 'node:fs'
import type { WebContents } from 'electron'
import { manifestFor } from '../shared/content/registry'
import { IpcChannel } from '../shared/ipc'
import type { LayoutSnapshot } from '../shared/layout'
import { LAYOUT_VERSION, layoutTrees, mapLayoutLeaves, ROOT_TAB_TITLE } from '../shared/layout'
import { createLeaf } from '../shared/model/factories'
import { sanitizeFloating } from '../shared/model/floating'
import { createId } from '../shared/model/ids'
import { collectLeaves, ensureTabsRoot, findNode, normalize } from '../shared/model/tree'
import type { ContentNode, NodeId } from '../shared/model/types'
import { EMPTY_TYPE, isEmpty, isPlausibleNode } from '../shared/model/types'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import type { JsonReadDeps, JsonWriteDeps } from './persist'
import { removeQuietly, saveJsonQuietly, userDataPath } from './persist'
import { getSettings } from './settings'
import type { WindowId } from './windows'

/**
 * Tab titles are otherwise a registry-driven, renderer-only concern (see
 * renderer/src/core/registry/titles.ts's `rootTabTitleForContent`) — main has
 * no content registry to ask, but the census (`CONTENT_TYPE_MANIFESTS`) is
 * readable from anywhere and carries the same `displayName`s the registry
 * derives its own from, so the wraps below (both of which always land their
 * content as a top-level tab of the docked root) mirror the renderer's
 * policy exactly: a content-less pane reads `ROOT_TAB_TITLE`, real content —
 * only reachable via `parseLayoutSnapshot`'s wrap of an old layout whose
 * root held real content — reads its census display name, and a type the
 * census doesn't know (a hand-edited file) falls back to its capitalized
 * type name.
 */
function fallbackTitle(node: ContentNode): string {
  if (isEmpty(node)) return ROOT_TAB_TITLE
  return (
    manifestFor(node.type)?.displayName ?? node.type.charAt(0).toUpperCase() + node.type.slice(1)
  )
}

/**
 * A fresh single empty pane, minted per call: node ids must be unique across
 * windows, since a pane can move between them. Repeated reads of one window
 * get the same object because `windowLayouts` caches it.
 */
function defaultLayout(): LayoutSnapshot {
  const leaf = createLeaf(EMPTY_TYPE)
  const root = ensureTabsRoot(leaf, fallbackTitle)
  return { version: LAYOUT_VERSION, root, activePaneId: leaf.id, floating: [] }
}

// ---------------------------------------------------------------------------
// The file
// ---------------------------------------------------------------------------

/** One pane-tree window's persisted layout, under the stable id windows.ts minted for it. */
interface WindowLayout {
  id: WindowId
  layout: LayoutSnapshot
}

function layoutPath(): string {
  return userDataPath('layout.json')
}

/**
 * One window's snapshot from its persisted form, or null on a version
 * mismatch or an implausible root (a recursive tree has no partial merge
 * over defaults the way settings do). The root is normalized to repair
 * drift, floating panes are repaired separately so a file from before they
 * existed still loads, and the root is wrapped in a tab group if it isn't
 * one already — `ensureTabsRoot`'s invariant must hold from the first read.
 * Every id the file named survives, the old root becoming the tab's content
 * by reference.
 */
function parseLayoutSnapshot(value: unknown): LayoutSnapshot | null {
  if (typeof value !== 'object' || value === null) return null
  const parsed = value as Record<string, unknown>
  if (parsed.version !== LAYOUT_VERSION || !isPlausibleNode(parsed.root)) return null
  const normalized = normalize(parsed.root)
  const root = ensureTabsRoot(normalized, fallbackTitle)
  const activePaneId = typeof parsed.activePaneId === 'string' ? parsed.activePaneId : normalized.id
  return {
    version: LAYOUT_VERSION,
    root,
    activePaneId,
    floating: sanitizeFloating(parsed.floating, root)
  }
}

/**
 * Every persisted window layout. A missing file, corrupt JSON or an
 * unrecognizable shape read as nothing persisted. Two shapes are read:
 * `{ windows: [{ id, layout }] }` is this build's own (a bad entry is
 * dropped, the rest kept); a bare snapshot is what builds before
 * multi-window support wrote, and becomes one window with a fresh id — the
 * next save writes it back in the new shape, which is the whole migration.
 */
export function loadLayoutFile({
  path = layoutPath(),
  readFile = (p) => readFileSync(p, 'utf-8')
}: JsonReadDeps = {}): WindowLayout[] {
  let parsed: unknown
  try {
    parsed = JSON.parse(readFile(path))
  } catch {
    return []
  }
  if (typeof parsed === 'object' && parsed !== null && 'windows' in parsed) {
    const windows = (parsed as { windows: unknown }).windows
    if (!Array.isArray(windows)) return []
    const loaded: WindowLayout[] = []
    for (const entry of windows) {
      if (typeof entry !== 'object' || entry === null) continue
      const { id, layout } = entry as { id?: unknown; layout?: unknown }
      const snapshot = parseLayoutSnapshot(layout)
      if (typeof id === 'string' && snapshot) loaded.push({ id, layout: snapshot })
    }
    return loaded
  }
  const legacy = parseLayoutSnapshot(parsed)
  return legacy ? [{ id: createId(), layout: legacy }] : []
}

/** Persists every window layout, never throwing (see persist.ts for why a throw here is a native error dialog). */
export function saveLayoutFile(windows: readonly WindowLayout[], deps: JsonWriteDeps = {}): void {
  saveJsonQuietly('layout', deps.path ?? layoutPath(), { windows }, deps.writeFile)
}

// ---------------------------------------------------------------------------
// Live state and IPC
// ---------------------------------------------------------------------------

/**
 * Every pane-tree window's layout by id — what `layout:get-sync`/`layout:set`
 * read and write, and exactly what `layout.json` holds: the windows to
 * restore next launch, in creation order.
 *
 * Closing a window while others remain drops it. Closing the *last* window
 * keeps it: a window's 'closed' fires before 'window-all-closed' and so
 * before `markQuitting`, so exiting by closing the only window (the normal
 * exit on Windows/Linux, close-then-Quit on macOS) would otherwise forget
 * the layout just before the quit that should have saved it. The kept entry
 * is also what a macOS reactivate brings back — and File → New Window with
 * no window open (see restoreWindows.ts) — so no fresh window is minted
 * while one is kept; `setWindowLayout` still purges it if one ever is.
 */
const windowLayouts = new Map<WindowId, LayoutSnapshot>()

/** windows.ts's registry keys, injected by `registerLayoutIpc`. */
let liveWindowIds: () => Iterable<WindowId> = () => []

/** Told whenever a closed window's layout is dropped, injected by `registerLayoutIpc` — see `LayoutWindowDeps.onWindowsDiscarded`. */
let onWindowsDiscarded: () => void = () => {}

/** Writes `windowLayouts` out; a no-op with persistence off, so turning it back on resumes from the live state. */
function persistLayoutFile(): void {
  if (!getSettings().persistLayoutOnExit) return
  saveLayoutFile([...windowLayouts].map(([id, layout]) => ({ id, layout })))
}

/**
 * Records `layout` as `windowId`'s and persists. A window seen for the first
 * time also purges entries whose windows are no longer live — the last-closed
 * one the rule above kept, which stops describing what will be open at quit
 * the moment a new window arrives. Nothing mints a fresh window while one is
 * kept (every way back to a window restores it), so this is a backstop.
 */
function setWindowLayout(windowId: WindowId, layout: LayoutSnapshot): void {
  let purged = false
  if (!windowLayouts.has(windowId)) {
    const live = new Set(liveWindowIds())
    for (const id of [...windowLayouts.keys()]) {
      if (!live.has(id)) purged = windowLayouts.delete(id) || purged
    }
  }
  windowLayouts.set(windowId, layout)
  persistLayoutFile()
  if (purged) onWindowsDiscarded()
}

/**
 * A window's layout after a cross-window detach or insert, persisted at once
 * rather than on its 400ms debounced save — a quit must not lose a move that
 * visibly completed. Dropped for a window that closed during the round trip:
 * its layout was forgotten on purpose, and recording it again would restore
 * at the next launch a window the user had closed.
 */
export function applyExternalSnapshot(windowId: WindowId, snapshot: LayoutSnapshot): void {
  if (![...liveWindowIds()].includes(windowId)) return
  setWindowLayout(windowId, snapshot)
}

/** The windows to (re)create when none are open: every persisted one at boot, the kept last-closed one on a macOS reactivate. Empty means "open one fresh window". */
export function restorableWindowIds(): WindowId[] {
  return [...windowLayouts.keys()]
}

/**
 * The live window whose last reported layout holds node `paneId`, docked or
 * floating. A cross-window move is recorded here at once (see
 * `applyExternalSnapshot`); a pane created in the last 400ms is not here yet,
 * and is still in whichever window created it.
 */
export function windowHoldingPane(paneId: string): WindowId | undefined {
  const live = new Set(liveWindowIds())
  for (const [windowId, layout] of windowLayouts) {
    if (!live.has(windowId)) continue
    if (layoutTrees(layout).some((tree) => findNode(tree, paneId))) return windowId
  }
  return undefined
}

/**
 * Every leaf id in `windowId`'s last reported layout, docked and floating —
 * what closing that window would end, for the close confirmation to ask
 * about. As fresh as the renderer's debounced save, so a pane opened in the
 * last 400ms may be missing from it.
 */
export function paneIdsOfWindow(windowId: WindowId): string[] {
  const layout = windowLayouts.get(windowId)
  if (!layout) return []
  return layoutTrees(layout).flatMap((tree) => collectLeaves(tree).map((leaf) => leaf.id))
}

/**
 * Set once quitting begins (see `refreshLeafConfigs`) so the *next* `layout:set`
 * — the renderer's final `beforeunload` flush, which always lands after
 * quitting starts, racing arbitrarily far behind it — gets each pane's live
 * config patched in too, rather than that later, structurally fresher but
 * unrefreshed snapshot silently overwriting what quitting just captured.
 * Never cleared in a normal run — once set, the app is on its way out for
 * good; only the e2e reset drops it, since a reused app lives on past the
 * quit that set it (see resetLayoutForTests). Applies to whichever window's
 * `layout:set` arrives next, regardless of which window that is.
 */
let pendingLeafPatches: ReadonlyMap<NodeId, LeafConfigPatch> | undefined

/**
 * e2e only: set while a reused app is being reset between tests (see
 * main/e2e.ts). The reset reloads the renderer, and that reload fires
 * layoutStore.ts's `beforeunload` flush — carrying the *outgoing* test's
 * layout, which would otherwise land after the reset already cleared
 * `windowLayouts` and repopulate it with stale state, leaking the previous
 * test's panes into the next one. Structurally the same "a late flush must
 * not overwrite what we already decided" problem `pendingLeafPatches`
 * handles at quit, minus the patching: mid-reset that flush has nothing
 * worth keeping, so it's dropped outright. Always cleared again once the
 * reload finishes.
 */
let resetting = false

/**
 * What `registerLayoutIpc` needs from windows.ts, injected rather than
 * imported: windows.ts needs `BrowserWindow` as a value, which the plain-Node
 * unit-test project this module's tests run under cannot load.
 */
interface LayoutWindowDeps {
  /** `windowIdForWebContents`: which pane-tree window an IPC call came from. */
  resolveWindowId: (webContents: WebContents) => WindowId | undefined
  /** `onPaneTreeWindowClosed`: a window closing while the app keeps running, with how many remain. */
  onWindowClosed: (listener: (windowId: WindowId, remaining: number) => void) => () => void
  /** Every live pane-tree window's id, read fresh at the point of use. */
  liveWindowIds: () => Iterable<WindowId>
  /**
   * A closed window's panes are gone for good — every window close outside
   * a quit, the last window's included (its layout is kept, not its panes),
   * and the backstop purge of a kept layout — so whatever still backs them
   * must be released (see MainPluginModule.onWindowDiscarded).
   */
  onWindowsDiscarded: () => void
}

/**
 * Loads every persisted window's layout and wires the window-aware get/set
 * channels; index.ts then asks `restorableWindowIds` which windows to open.
 * Both directions are gated on `persistLayoutOnExit`: off, boot starts fresh
 * and nothing writes, but nothing is deleted either.
 */
export function registerLayoutIpc(deps: LayoutWindowDeps): void {
  const { resolveWindowId, onWindowClosed } = deps
  liveWindowIds = deps.liveWindowIds
  onWindowsDiscarded = deps.onWindowsDiscarded

  if (getSettings().persistLayoutOnExit) {
    for (const { id, layout } of loadLayoutFile()) windowLayouts.set(id, layout)
    // Written straight back: a pre-multi-window file is migrated here, once.
    if (windowLayouts.size > 0) persistLayoutFile()
  }

  registerSyncGetter(IpcChannel.layoutGetSync, (event) => {
    const windowId = resolveWindowId(event.sender)
    if (!windowId) return defaultLayout()
    const known = windowLayouts.get(windowId)
    if (known) return known
    // Persisted on first read, so a never-edited window survives a relaunch.
    const fresh = defaultLayout()
    setWindowLayout(windowId, fresh)
    return fresh
  })
  onRendererMessage(IpcChannel.layoutSet, (event, snapshot: LayoutSnapshot) => {
    if (resetting) return
    const windowId = resolveWindowId(event.sender)
    if (!windowId) return
    // The patch walk recurses over a renderer-supplied snapshot, and it runs
    // at the one moment the app is least able to survive a throw, since
    // pendingLeafPatches is only set once quitting has begun. A throw lands in
    // onRendererMessage's guard before the assignment, so a malformed snapshot
    // keeps the previous one.
    const patched = pendingLeafPatches
      ? withPatchedLeafConfigs(snapshot, pendingLeafPatches)
      : snapshot
    setWindowLayout(windowId, patched)
  })
  onWindowClosed((windowId, remaining) => {
    // The last window's layout stays, for a reactivate and for the quit that
    // may follow, but its panes end like any closed window's: a reactivate
    // brings the layout back on fresh shells, as a relaunch would.
    if (remaining > 0 && windowLayouts.delete(windowId)) persistLayoutFile()
    onWindowsDiscarded()
  })
}

/** e2e only: forgets every window's layout and clears the file, so a reused app starts the next test fresh (see main/e2e.ts). */
export function resetLayoutForTests(): void {
  windowLayouts.clear()
  pendingLeafPatches = undefined
  removeQuietly(layoutPath())
}

/** e2e only: see `resetting` above. */
export function setLayoutResetting(value: boolean): void {
  resetting = value
}

/** Keys to merge over a leaf's existing `config` — the same shape `LeafContent.config` already is. */
export type LeafConfigPatch = Readonly<Record<string, unknown>>

/**
 * Pure transform: returns `layout` with each leaf named in `patches` (keyed by
 * leaf id) given those keys merged over its `config` — keys the patch doesn't
 * mention are kept rather than blanked out, and a leaf with no entry is
 * untouched. There is no type filter, and no key list either: the caller's map
 * decides both which leaves are patched and what with, so core names neither a
 * content type nor a config key of one.
 *
 * That generality is what a second caller will need — the terminal (today's
 * only one) refreshes `cwd`, which its shell has been changing all session;
 * a browser pane's `url` is the same story waiting to be told, set once at
 * creation and stale from the first navigation.
 *
 * Floating panes are walked too: a pane lifted out of the docked layout is
 * still live, and skipping it would silently restore it in its stale
 * creation-time state. Returns `layout` itself, unchanged, when nothing
 * anywhere changes — `refreshLeafConfigs` uses that identity to decide whether
 * a save is even needed.
 */
export function withPatchedLeafConfigs(
  layout: LayoutSnapshot,
  patches: ReadonlyMap<NodeId, LeafConfigPatch>
): LayoutSnapshot {
  if (patches.size === 0) return layout
  return mapLayoutLeaves(layout, (leaf) => {
    const entry = patches.get(leaf.id)
    return entry === undefined ? leaf : { ...leaf, config: { ...leaf.config, ...entry } }
  })
}

/**
 * Best-effort refresh of the persisted config of every pane the caller names,
 * to whatever that pane's live state actually is, then saves — called once at
 * quit so a restored session reopens each pane as it actually was. Synchronous
 * throughout: quitting cannot await (see CLAUDE.md's before-quit gotcha).
 *
 * Both probes are arguments, and *what* they refresh is the caller's business
 * too — which is what keeps this file free of any content type: layout.ts
 * imports nothing from terminal.ts, and the terminal module passes its own
 * pair, plus the `cwd` key they mean, from its onQuitSync hook (see
 * src/plugins/terminal/main/index.ts).
 *
 * Ids come from `listPaneIds` (a live registry), not any window's tree: the
 * renderer's debounced save means a window's entry in `windowLayouts` can lag
 * behind its session's latest structural change, while the registry is
 * exactly "every such pane that exists right now", whichever window it's
 * in. `pendingLeafPatches` (above) then patches the fresher snapshot that
 * arrives after quitting starts, instead of letting it clobber what was just
 * captured. No-ops when persistLayoutOnExit is off, matching `layout:set`'s
 * own gating.
 */
export function refreshLeafConfigs(
  listPaneIds: () => readonly string[],
  getLivePatch: (id: string) => LeafConfigPatch | undefined
): void {
  if (!getSettings().persistLayoutOnExit) return
  const paneIds = listPaneIds()
  if (paneIds.length === 0) return

  const patches = new Map<NodeId, LeafConfigPatch>()
  for (const id of paneIds) {
    const patch = getLivePatch(id)
    if (patch) patches.set(id, patch)
  }
  if (patches.size === 0) return
  pendingLeafPatches = patches

  let changed = false
  for (const [windowId, snapshot] of windowLayouts) {
    const refreshed = withPatchedLeafConfigs(snapshot, patches)
    if (refreshed === snapshot) continue
    windowLayouts.set(windowId, refreshed)
    changed = true
  }
  if (changed) persistLayoutFile()
}
