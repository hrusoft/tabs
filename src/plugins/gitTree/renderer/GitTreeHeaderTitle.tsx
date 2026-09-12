import './gitTree.css'
import type { LeafContent } from '@shared/model/types'
import { useEffect, useRef, useState } from 'react'
import { HeaderButton } from '../../../renderer/src/plugin/api'
import type { GitBranchScope, GitHead } from '../shared/types'
import { shortHash } from './format'
import { gitTreeBridge } from './gitTreeBridge'
import { FolderIcon } from './gitTreeIcons'
import { gitTreeHeads } from './gitTreeRegistry'
import { gitTreeCtx } from './pluginContext'

function headLabel(head: GitHead): string {
  return head.kind === 'branch' ? head.name : `detached at ${shortHash(head.hash)}`
}

/** The branch-scope dropdown's options, in the order the issue specifies them. */
const BRANCH_SCOPE_OPTIONS: Array<{ value: GitBranchScope; label: string }> = [
  { value: 'current', label: 'Current branch' },
  { value: 'local', label: 'All local branches' },
  { value: 'all', label: 'All branches' }
]

/**
 * The git tree's `ContentRendererDef.HeaderTitle` — the path bar, browse
 * button, HEAD label and branch-scope select, replacing the pane header's
 * whole title slot. Used to be `GitTreeRenderer`'s own `.git-tree-toolbar`;
 * now the header *is* the toolbar, and the body holds only the commit list
 * and detail panel.
 *
 * Reads the HEAD label reactively via `gitTreeHeads` rather than a one-time
 * lookup (see gitTreeRegistry.ts's own doc for why: `Pane.tsx` mounts this
 * component before the body publishes anything). Everything else here
 * (`chooseDirectory`/`applyPath`/`browse`/`chooseBranchScope`) writes through
 * `setLeafConfig`/`gitTreeBridge` directly — `gitTreeCtx` is a module-level
 * context holder, not scoped to whichever component happens to call it.
 *
 * The branch scope is read straight from config, the way `GitTreeRenderer`
 * reads it: the select is its only writer, and both components re-render
 * from the same store subscription when it changes, so a local copy would
 * only be a second value to keep in step. Only the path bar mirrors config,
 * because it holds text the user is mid-typing.
 */
export function GitTreeHeaderTitle({ leaf }: { leaf: LeafContent }) {
  const configuredDir = leaf.config.cwd as string | undefined
  const pathInputRef = useRef<HTMLInputElement>(null)
  const [pathValue, setPathValue] = useState(configuredDir ?? '')
  const branchScope = (leaf.config.branchScope as GitBranchScope | undefined) ?? 'all'
  const head = gitTreeHeads.use(leaf.id)

  /**
   * Whether anything has chosen a directory for this pane yet.
   *
   * A ref rather than state because its only job is to be readable from inside
   * an in-flight promise — see the default-directory effect below, which must
   * not overwrite a choice made while it was waiting.
   */
  const directoryChosen = useRef(configuredDir !== undefined)

  // Keep the path bar showing the pane's actual directory when that changes
  // from anywhere but this input — the browse button, or a restored layout
  // arriving after first paint.
  //
  // Never while the caret is *in* the path bar, though. A pane opens with no
  // directory and adopts one asynchronously, so without this guard a user who
  // opens a git tree and immediately types a path has their half-typed input
  // replaced by the default the moment it arrives — and the value they then
  // submit is the one that was pushed at them. Found by an e2e test doing
  // exactly that, faster than a person could.
  useEffect(() => {
    if (document.activeElement === pathInputRef.current) return
    setPathValue(configuredDir ?? '')
  }, [configuredDir])

  /**
   * A pane created with no directory adopts one.
   *
   * This is the fallback for when creation inherited nothing — a pane whose
   * origin had a directory to offer arrives with `cwd` already set by
   * `deriveConfig` (see gitTreeContentDef.ts) and never reaches this. Main
   * answers with the app's own working directory when that is a repository
   * and the home directory otherwise, and either way the answer is written
   * into config so the pane stops being directory-less — including across a
   * restart.
   */
  useEffect(() => {
    if (configuredDir !== undefined) return
    let cancelled = false
    void gitTreeBridge.defaultDirectory().then((dir) => {
      // Two guards, and both are needed. `cancelled` covers the pane
      // unmounting or its directory arriving from elsewhere before this
      // resolved; `directoryChosen` covers the narrower window where a choice
      // was made *during* the round trip but React has not re-run this effect
      // yet. A default silently overwriting a directory the user picked is the
      // worst outcome available here, so it is checked twice rather than
      // relying on render timing.
      if (cancelled || directoryChosen.current) return
      directoryChosen.current = true
      gitTreeCtx.get().layout.setLeafConfig(leaf.id, { cwd: dir })
    })
    return () => {
      cancelled = true
    }
  }, [configuredDir, leaf.id])

  const chooseDirectory = (dir: string): void => {
    directoryChosen.current = true
    gitTreeCtx.get().layout.setLeafConfig(leaf.id, { cwd: dir })
  }

  const applyPath = (): void => {
    const next = pathValue.trim()
    if (next.length === 0 || next === configuredDir) return
    chooseDirectory(next)
  }

  const chooseBranchScope = (scope: GitBranchScope): void => {
    gitTreeCtx.get().layout.setLeafConfig(leaf.id, { branchScope: scope })
  }

  const browse = async (): Promise<void> => {
    const chosen = await gitTreeBridge.chooseDirectory(configuredDir)
    // Undefined is "cancelled" — and is what the handler always answers under
    // E2E_HIDDEN, where a native picker would hang the run.
    if (chosen === undefined) return
    chooseDirectory(chosen)
  }

  return (
    <>
      <input
        ref={pathInputRef}
        className="git-tree-path-input"
        data-testid="git-tree-path-input"
        aria-label="Repository directory"
        spellCheck={false}
        value={pathValue}
        onChange={(event) => setPathValue(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter') applyPath()
          if (event.key === 'Escape') setPathValue(configuredDir ?? '')
          // The list's own handler is on an ancestor, so an arrow press
          // inside the input would move the selection as well as the caret.
          event.stopPropagation()
        }}
        onBlur={applyPath}
      />
      <HeaderButton
        testId="git-tree-browse-button"
        label="Choose a repository"
        onPress={() => void browse()}
      >
        <FolderIcon />
      </HeaderButton>
      {head && (
        <span className="git-tree-head" data-testid="git-tree-head">
          {headLabel(head)}
        </span>
      )}
      <select
        className="git-tree-branch-select"
        data-testid="git-tree-branch-scope"
        aria-label="Branches shown"
        value={branchScope}
        onChange={(event) => chooseBranchScope(event.target.value as GitBranchScope)}
      >
        {BRANCH_SCOPE_OPTIONS.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </>
  )
}
