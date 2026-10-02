import { memo } from 'react'
import type { CommitDetail } from '../shared/types'
import { UNCOMMITTED_CHANGES_HASH } from '../shared/types'
import { formatDate, shortHash } from './format'

/**
 * The selected row's detail: its message, identity fields and changed files —
 * or, for the working-tree row, the same shape minus the fields a commit has
 * and uncommitted state doesn't. Memoized: a divider drag re-renders the pane
 * every frame, with the same `detail` throughout.
 */
function CommitDetailPanelImpl({ detail }: { detail: CommitDetail | undefined }) {
  return (
    <div className="git-tree-detail" data-testid="git-tree-detail">
      {detail ? (
        <>
          <pre className="git-tree-message" data-testid="git-tree-message">
            {detail.message}
          </pre>
          <dl className="git-tree-fields">
            {detail.hash !== UNCOMMITTED_CHANGES_HASH && (
              <>
                <dt>Commit</dt>
                <dd data-testid="git-tree-detail-hash">{detail.hash}</dd>
                <dt>Author</dt>
                <dd>{`${detail.author} <${detail.authorEmail}>`}</dd>
                <dt>Date</dt>
                {/* The same formatter the rows use. Showing the raw `%aI`
                    here instead reads as a bug rather than as precision:
                    the same commit displays two different-looking times,
                    one local and one in the author's offset. */}
                <dd>{formatDate(detail.date)}</dd>
              </>
            )}
            {detail.parents.length > 0 && (
              <>
                <dt>{detail.parents.length > 1 ? 'Parents' : 'Parent'}</dt>
                <dd>{detail.parents.map(shortHash).join(', ')}</dd>
              </>
            )}
            {detail.refs.length > 0 && (
              <>
                <dt>Refs</dt>
                <dd>{detail.refs.join(', ')}</dd>
              </>
            )}
          </dl>
          <div className="git-tree-files" data-testid="git-tree-files">
            {detail.files.map((file) => (
              <div key={file.path} className="git-tree-file" data-testid="git-tree-file">
                <span className="git-tree-file-stat">
                  {file.insertions === null || file.deletions === null ? (
                    <span className="git-tree-binary">binary</span>
                  ) : (
                    <>
                      <span className="git-tree-insertions">+{file.insertions}</span>
                      <span className="git-tree-deletions">−{file.deletions}</span>
                    </>
                  )}
                </span>
                <span className="git-tree-file-path">{file.path}</span>
              </div>
            ))}
            {detail.files.length === 0 &&
              (detail.hash === UNCOMMITTED_CHANGES_HASH ? (
                <p className="git-tree-dim">No uncommitted changes.</p>
              ) : (
                <p className="git-tree-dim">No files changed against the first parent.</p>
              ))}
            {detail.filesTruncated && (
              <p className="git-tree-dim">Only the first files are listed.</p>
            )}
          </div>
        </>
      ) : (
        <p className="git-tree-dim">Select a commit.</p>
      )}
    </div>
  )
}

export const CommitDetailPanel = memo(CommitDetailPanelImpl)
