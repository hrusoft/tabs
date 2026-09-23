import { memo } from 'react'
import type { GraphRow } from '../shared/graph'
import { UNCOMMITTED_CHANGES_HASH } from '../shared/types'
import { formatDate, shortHash } from './format'
import { GitGraph } from './GitGraph'

/**
 * One row — a real commit, or (when `row.commit.hash === UNCOMMITTED_CHANGES_HASH`)
 * the working tree's own uncommitted state, rendered by the same component so
 * it gets everything a real row gets for free: a place in the lane graph (its
 * synthetic `Commit` carries the newest real commit as its one parent, so
 * `assignLanes` draws it connected into the tree rather than as a separate
 * decoration), selection, and keyboard navigation. The row itself is dimmed
 * via `.git-tree-row-phantom` (opacity on the whole row, gutter included, so
 * even its lane color reads as receded rather than needing a color of its
 * own); everything else it shows — the label as its subject, blank hash/
 * author/date, no refs — is simply what its synthetic `Commit` carries, so
 * nothing below special-cases it.
 *
 * Memoized so a selection change reconciles only the two rows whose
 * `selected` flipped instead of rebuilding every row's SVG — the row data is
 * already stable across selection changes (`graph` is memoized on the
 * commits), so without this each key-repeat of a held arrow re-rendered the
 * whole list.
 */
function CommitRowImpl({
  row,
  laneCount,
  selected,
  id,
  showAuthor,
  showDate,
  onSelect,
  onCheckout,
  onCommitMenu
}: {
  row: GraphRow
  laneCount: number
  selected: boolean
  id: string
  showAuthor: boolean
  showDate: boolean
  onSelect: (hash: string) => void
  /** Double-click's target — does the same as choosing Checkout from the row's context menu. Never called for the working-tree row (see below). */
  onCheckout: (hash: string) => void
  /** Right-click's target: opens the row's context menu (Checkout, Copy SHA-1) at the given point. Never called for the working-tree row (see below). */
  onCommitMenu: (hash: string, x: number, y: number) => void
}) {
  const isWorkingTree = row.commit.hash === UNCOMMITTED_CHANGES_HASH
  // The commit HEAD currently points at — parseRefs (git.ts) splits `HEAD ->
  // main` into separate ref strings for exactly this check.
  const isHead = row.commit.refs.includes('HEAD')
  const className = [
    'git-tree-row',
    selected && 'git-tree-row-selected',
    isWorkingTree && 'git-tree-row-phantom'
  ]
    .filter(Boolean)
    .join(' ')
  return (
    // biome-ignore lint/a11y/useKeyWithClickEvents: the keyboard equivalent is the list's own onKeyDown, which is the whole point of the activedescendant pattern — a per-row handler could only fire for a row that had focus, and no row ever does
    <div
      id={id}
      className={className}
      data-testid="git-tree-row"
      data-hash={row.commit.hash}
      role="option"
      aria-selected={selected}
      // Out of the tab sequence but programmatically focusable, which is what
      // an option in an activedescendant listbox should be — the container is
      // the tab stop, not the row.
      tabIndex={-1}
      onClick={() => onSelect(row.commit.hash)}
      // Nothing in the menu has a meaning for the synthetic uncommitted-changes
      // row — there is no commit to check out and no hash to copy — so neither
      // handler is even wired for it, rather than being wired and then
      // guarded: a stray call is structurally impossible instead of merely
      // refused.
      onDoubleClick={isWorkingTree ? undefined : () => onCheckout(row.commit.hash)}
      onContextMenu={
        isWorkingTree
          ? undefined
          : (event) => {
              event.preventDefault()
              // Right-click selects the row it opens on, the same as a plain
              // click would — so the detail panel below always shows the
              // commit the menu (and any dialog it leads to) is acting on.
              onSelect(row.commit.hash)
              onCommitMenu(row.commit.hash, event.clientX, event.clientY)
            }
      }
    >
      <GitGraph row={row} laneCount={laneCount} selected={selected} isHead={isHead} />
      <span className="git-tree-hash">{shortHash(row.commit.hash)}</span>
      <span className="git-tree-subject">
        {row.commit.refs.map((ref) => (
          <span
            key={ref}
            className={isHead ? 'git-tree-ref git-tree-ref-head' : 'git-tree-ref'}
            data-testid="git-tree-ref"
          >
            {ref}
          </span>
        ))}
        {row.commit.subject}
      </span>
      {showAuthor && (
        <span className="git-tree-author" data-testid="git-tree-author">
          {row.commit.author}
        </span>
      )}
      {showDate && (
        <span className="git-tree-date" data-testid="git-tree-date">
          {formatDate(row.commit.date)}
        </span>
      )}
    </div>
  )
}

export const CommitRow = memo(CommitRowImpl)
