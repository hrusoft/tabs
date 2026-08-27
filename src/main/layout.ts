import { readFileSync } from 'node:fs'
import { manifestFor } from '../shared/content/registry'
import { IpcChannel } from '../shared/ipc'
import type { LayoutSnapshot } from '../shared/layout'
import { LAYOUT_VERSION, ROOT_TAB_TITLE } from '../shared/layout'
import { createLeaf } from '../shared/model/factories'
import { sanitizeFloating } from '../shared/model/floating'
import { ensureTabsRoot, mapLeaves, normalize } from '../shared/model/tree'
import type { ContentNode, LeafContent, NodeId } from '../shared/model/types'
import { EMPTY_TYPE, isEmpty, isPlausibleNode } from '../shared/model/types'
import { onRendererMessage, registerSyncGetter } from './ipcListeners'
import type { JsonReadDeps, JsonWriteDeps } from './persist'
import { removeQuietly, saveJsonQuietly, userDataPath } from './persist'
import { getSettings } from './settings'

/**
 * Tab titles are otherwise a registry-driven, renderer-only concern (see
 * renderer/src/core/registry/titles.ts's `rootTabTitleForContent`) — main has
 * no content registry to ask, but the census (`CONTENT_TYPE_MANIFESTS`) is
 * readable from anywhere and carries the same `displayName`s the registry
 * derives its own from, so the wraps below (both of which always land their
 * content as a top-level tab of the docked root) mirror the renderer's
 * policy exactly: a content-less pane reads `ROOT_TAB_TITLE`, real content —
 * only reachable via `loadLayout`'s migration of an old layout whose root
 * held real content — reads its census display name, and a type the census
 * doesn't know (a hand-edited file) falls back to its capitalized type name.
 */
function fallbackTitle(node: ContentNode): string {
  if (isEmpty(node)) return ROOT_TAB_TITLE
  return (
    manifestFor(node.type)?.displayName ?? node.type.charAt(0).toUpperCase() + node.type.slice(1)
  )
}

function defaultLayout(): LayoutSnapshot {
  const leaf = createLeaf(EMPTY_TYPE)
  const root = ensureTabsRoot(leaf, fallbackTitle)
  return { version: LAYOUT_VERSION, root, activePaneId: leaf.id, floating: [] }
}

/**
 * A single shared instance, like settings.ts's `DEFAULT_SETTINGS` — every
 * fallback path returns this same object rather than minting a fresh one, so
 * repeated loads (or a first run followed by a reload) don't hand out a
 * different random root id each time. Safe to share: nothing in the model
 * mutates a `ContentNode` in place, every tree operation returns a new one.
 */
export const DEFAULT_LAYOUT: LayoutSnapshot = defaultLayout()

function layoutPath(): string {
  return userDataPath('layout.json')
}

/**
 * Reads the persisted layout from disk. Missing file, corrupt JSON, a
 * mismatched version, or a root that isn't plausibly a ContentNode all fall
 * back to a fresh single empty pane (there's no partial-merge equivalent for
 * a recursive tree the way settings merges over defaults). A parsed root that
 * passes the shape check is run through `normalize` to repair any drift
 * (stale activeTabId, empty splits, etc.) before use. Floating panes are
 * additive and repaired separately (see `sanitizeFloating`), so a file written
 * before they existed — or one whose floating list is unusable — still loads
 * its docked layout intact.
 *
 * The docked root is then wrapped in a tab group if it isn't already one —
 * the window has no chrome of its own any more, so the invariant that its
 * own root tab bar depends on (`ensureTabsRoot`, also enforced live by the
 * renderer's `layoutStore`) has to hold from the very first read too, not
 * just from here on: a layout saved before this invariant existed is exactly
 * as "old" as one saved five minutes ago once it's back on disk. Every id an
 * old file named — `activePaneId` included — survives the wrap unchanged,
 * since the old root becomes the new tab's content by reference rather than
 * being rebuilt.
 */
export function loadLayout({
  path = layoutPath(),
  readFile = (p) => readFileSync(p, 'utf-8')
}: JsonReadDeps = {}): LayoutSnapshot {
  try {
    const parsed = JSON.parse(readFile(path))
    if (parsed?.version !== LAYOUT_VERSION || !isPlausibleNode(parsed.root)) return DEFAULT_LAYOUT
    const normalized = normalize(parsed.root)
    const root = ensureTabsRoot(normalized, fallbackTitle)
    const activePaneId =
      typeof parsed.activePaneId === 'string' ? parsed.activePaneId : normalized.id
    return {
      version: LAYOUT_VERSION,
      root,
      activePaneId,
      floating: sanitizeFloating(parsed.floating, root)
    }
  } catch {
    return DEFAULT_LAYOUT
  }
}

/**
 * Persists the layout, best-effort: the write is wrapped so that nothing can
 * throw out of here, whatever writer is in play (see persist.ts for why an
 * escaping throw here is a native error dialog rather than a lost save). The
 * default writer also creates the userData directory if it has gone missing.
 */
export function saveLayout(layout: LayoutSnapshot, deps: JsonWriteDeps = {}): void {
  saveJsonQuietly('layout', deps.path ?? layoutPath(), layout, deps.writeFile)
}

let current: LayoutSnapshot

/**
 * Set once quitting begins (see `refreshLeafConfigs`) so the *next* `layout:set`
 * — the renderer's final `beforeunload` flush, which always lands after
 * quitting starts, racing arbitrarily far behind it — gets each pane's live
 * config patched in too, rather than that later, structurally fresher but
 * unrefreshed snapshot silently overwriting what quitting just captured.
 * Never cleared in a normal run — once set, the app is on its way out for
 * good; only the e2e reset drops it, since a reused app lives on past the
 * quit that set it (see resetLayoutForTests).
 */
let pendingLeafPatches: ReadonlyMap<NodeId, LeafConfigPatch> | undefined

/**
 * e2e only: set while a reused app is being reset between tests (see
 * main/e2e.ts). The reset reloads the renderer, and that reload fires
 * layoutStore.ts's `beforeunload` flush — carrying the *outgoing* test's
 * layout, which lands after `current` was reset back to the default and
 * would otherwise clobber it, leaking the previous test's panes into the
 * next one. Structurally the same "a late flush must not overwrite what we
 * already decided" problem `pendingLeafPatches` handles at quit, minus the
 * patching: mid-reset that flush has nothing worth keeping, so it's dropped
 * outright. Always cleared again once the reload finishes.
 */
let resetting = false

/**
 * Loads the persisted layout once and wires up the get/set IPC channels.
 * Both directions are gated on settings.ts's `persistLayoutOnExit`: when
 * it's off, boot ignores whatever is on disk (starts fresh) and `layout:set`
 * stops writing to disk, without deleting the file — so flipping the setting
 * back on later resumes persisting from wherever the session is at, rather
 * than losing the old save.
 */
export function registerLayoutIpc(): void {
  current = getSettings().persistLayoutOnExit ? loadLayout() : DEFAULT_LAYOUT
  registerSyncGetter(IpcChannel.layoutGetSync, () => current)
  onRendererMessage(IpcChannel.layoutSet, (_event, snapshot: LayoutSnapshot) => {
    if (resetting) return
    // The patch walk recurses over a renderer-supplied snapshot, and it runs
    // at the one moment the app is least able to survive a throw, since
    // pendingLeafPatches is only set once quitting has begun. A throw lands in
    // onRendererMessage's guard before the assignment, so a malformed snapshot
    // keeps the previous one.
    current = pendingLeafPatches ? withPatchedLeafConfigs(snapshot, pendingLeafPatches) : snapshot
    if (getSettings().persistLayoutOnExit) saveLayout(current)
  })
}

/**
 * e2e only: drops the in-memory layout back to a pristine single empty pane
 * and clears the persisted copy, so a reused app starts the next test where a
 * freshly launched one would. See `resetting` above for why `layout:set` is
 * gated for the duration, and main/e2e.ts for the whole sequence.
 */
export function resetLayoutForTests(): void {
  current = DEFAULT_LAYOUT
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
  const patch = (leaf: LeafContent): LeafContent => {
    const entry = patches.get(leaf.id)
    return entry === undefined ? leaf : { ...leaf, config: { ...leaf.config, ...entry } }
  }
  const root = mapLeaves(layout.root, patch)
  let floatingChanged = false
  const floating = layout.floating?.map((entry) => {
    const content = mapLeaves(entry.content, patch)
    if (content === entry.content) return entry
    floatingChanged = true
    return { ...entry, content }
  })
  if (root === layout.root && !floatingChanged) return layout
  return floating ? { ...layout, root, floating } : { ...layout, root }
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
 * Ids come from `listPaneIds` (a live registry), not `current`'s tree: the
 * renderer's debounced save means `current` can lag behind the session's
 * latest structural change, while the registry is exactly "every such pane
 * that exists right now". `pendingLeafPatches` (above) then patches the fresher
 * snapshot that arrives after quitting starts, instead of letting it clobber
 * what was just captured. No-ops when persistLayoutOnExit is off, matching
 * `layout:set`'s own gating.
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

  const refreshed = withPatchedLeafConfigs(current, patches)
  if (refreshed === current) return
  current = refreshed
  saveLayout(current)
}
