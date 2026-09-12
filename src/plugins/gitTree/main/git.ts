import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type {
  ChangedFile,
  Commit,
  GitBranchScope,
  GitCommitResult,
  GitFailure,
  GitHead,
  GitLogResult
} from '../shared/types'
import { UNCOMMITTED_CHANGES_HASH } from '../shared/types'

const run = promisify(execFile)

/**
 * Reading a repository by shelling out to `git`.
 *
 * `git` rather than a JS library, for the same reason this codebase already
 * shells out to `lsof`/`ps`: no new dependency, no native build, and the
 * user's own git — with their config, their hooks disabled or not, their
 * `includeIf` rules — is the one whose answer they expect to see.
 *
 * Two rules hold everywhere in this file.
 *
 * **Asynchronous, always.** Nothing here may ever be called from
 * `before-quit`; the git tree module deliberately declares no `onQuitSync`
 * hook, because it has nothing to flush and nothing to tear down. CLAUDE.md's
 * before-quit gotcha is four incidents long and every one of them started with
 * a child process spawned near shutdown.
 *
 * **Never a rejection.** Every failure — `git` missing, not a repo, an empty
 * repo, a hash that doesn't exist — comes back as a `GitFailure`, because all
 * of them are ordinary states for a pane to be sitting in. A rejected promise
 * would cross the IPC boundary as an opaque `Error invoking remote method`
 * string, which is exactly the shape of message the browser type's
 * `executeScript` had to be built to avoid.
 */

/** Field separator: ASCII unit separator, which no ref name, path or subject line can contain. */
const SEP = '\x1f'

/** How long any single invocation may take before it is killed. A repo on a stalled network mount must not wedge a pane. */
const TIMEOUT_MS = 10_000

/** Output cap per invocation. A 5,000-file merge is the realistic worst case and lands far under this. */
const MAX_BUFFER = 32 * 1024 * 1024

/**
 * Files listed for one commit. A vendored-dependency bump can touch tens of
 * thousands; past this the list stops being readable and starts being a
 * rendering cost, so it is cut and the panel says so.
 */
const FILE_CAP = 500

/**
 * Args every invocation carries.
 *
 * `core.quotePath=false` keeps non-ASCII paths as raw UTF-8 rather than
 * `"\303\251"` octal escapes, which is what git does by default and would
 * otherwise reach the UI verbatim. `--no-pager` because a pager attached to a
 * non-tty is merely useless, not harmful, but saying so costs nothing.
 */
const BASE_ARGS = ['-c', 'core.quotePath=false', '--no-pager']

interface GitOutput {
  ok: true
  stdout: string
}

type GitInvocation = GitOutput | { ok: false; reason: GitFailure }

/**
 * One `git` invocation in `cwd`, with every failure mapped to a `GitFailure`.
 *
 * The classification is done on stderr text, which is the only thing git
 * offers: exit codes are 1 or 128 for nearly everything. Matching is on the
 * stable phrases ("not a git repository", "does not have any commits yet")
 * that git has emitted for well over a decade; anything unrecognized becomes
 * `failed` with the real stderr attached, so an unclassified error still
 * reaches the user as words rather than as silence.
 */
async function git(cwd: string, args: string[]): Promise<GitInvocation> {
  try {
    const { stdout } = await run('git', [...BASE_ARGS, ...args], {
      cwd,
      timeout: TIMEOUT_MS,
      maxBuffer: MAX_BUFFER,
      windowsHide: true,
      // A repo's own hooks and config must not be able to prompt for input:
      // an editor or a credential helper waiting on stdin would hang the
      // invocation until the timeout above.
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0' }
    })
    return { ok: true, stdout }
  } catch (error) {
    return { ok: false, reason: classify(error, cwd) }
  }
}

function classify(error: unknown, cwd: string): GitFailure {
  const record = error as { code?: unknown; stderr?: unknown; message?: unknown }
  // ENOENT from execFile is ambiguous: it fires both when the *binary* is
  // missing and when `cwd` itself doesn't exist (the path bar writes
  // whatever the user typed with no existence check). A stat tells them
  // apart — "git isn't installed" is actively wrong for a typo'd path.
  if (record.code === 'ENOENT') {
    return existsSync(cwd) ? { kind: 'git-missing' } : { kind: 'no-such-directory', path: cwd }
  }

  const stderr = typeof record.stderr === 'string' ? record.stderr : ''
  const message = stderr || (typeof record.message === 'string' ? record.message : 'git failed')
  const lower = message.toLowerCase()

  if (lower.includes('not a git repository')) return { kind: 'not-a-repo', path: cwd }
  // A freshly `git init`ed directory: `rev-parse --show-toplevel` succeeds and
  // only `log` fails. Distinct from not-a-repo on purpose — telling someone
  // their brand-new repo isn't a repo is worse than saying nothing.
  if (lower.includes('does not have any commits yet') || lower.includes('bad default revision')) {
    return { kind: 'no-commits', root: cwd }
  }
  return { kind: 'failed', message: firstLine(message) }
}

function firstLine(text: string): string {
  const line = text.split('\n').find((candidate) => candidate.trim().length > 0)
  return (line ?? 'git failed').trim()
}

type RepoRoot = { ok: true; root: string } | { ok: false; reason: GitFailure }

/** The repository root containing `dir`, or why there isn't one. */
async function repoRoot(dir: string): Promise<RepoRoot> {
  const result = await git(dir, ['rev-parse', '--show-toplevel'])
  if (!result.ok) return result
  return { ok: true, root: result.stdout.trim() }
}

/**
 * Ref names pointing at a commit, out of `%D`.
 *
 * `%D` renders the current branch as `HEAD -> main`, which is one decoration
 * describing two things; split so the UI can badge HEAD distinctly without
 * parsing an arrow.
 */
function parseRefs(decoration: string): string[] {
  const refs: string[] = []
  for (const part of decoration.split(', ')) {
    const ref = part.trim()
    if (ref.length === 0) continue
    if (ref.startsWith('HEAD -> ')) {
      refs.push('HEAD', ref.slice('HEAD -> '.length))
      continue
    }
    refs.push(ref)
  }
  return refs
}

const LOG_FORMAT = ['%H', '%P', '%an', '%aI', '%D', '%s'].join('%x1f')

function parseLogLine(line: string): Commit | undefined {
  const fields = line.split(SEP)
  if (fields.length < 6) return undefined
  // The defaults never fire — the length guard above is what establishes the
  // shape — but they type the destructuring without restating it as a cast.
  const [hash = '', parents = '', author = '', date = '', decoration = '', subject = ''] = fields
  return {
    hash,
    // A root commit has an empty %P, which `split(' ')` would turn into [''].
    parents: parents.length > 0 ? parents.split(' ') : [],
    author,
    date,
    refs: parseRefs(decoration),
    subject
  }
}

/** Where HEAD is. `symbolic-ref` exits non-zero exactly when it is detached, which is what distinguishes the two. */
async function readHead(dir: string): Promise<GitHead> {
  const branch = await git(dir, ['symbolic-ref', '--quiet', '--short', 'HEAD'])
  if (branch.ok) return { kind: 'branch', name: branch.stdout.trim() }
  const hash = await git(dir, ['rev-parse', 'HEAD'])
  return { kind: 'detached', hash: hash.ok ? hash.stdout.trim() : 'HEAD' }
}

/** The `git log` ref-selection args for each branch scope — see `GitBranchScope`. */
function scopeArgs(scope: GitBranchScope): string[] {
  switch (scope) {
    case 'current':
      return ['HEAD']
    case 'local':
      return ['--branches']
    case 'all':
      return ['--branches', '--remotes']
  }
}

/**
 * A page of history, scoped to `branchScope` — the point of drawing a graph is
 * to show the branches, so even the narrowest scope still asks git for real
 * ref-reachable history rather than `--first-parent`, which would be a list
 * wearing a gutter. `--date-order` keeps the rows in a shape a reader expects
 * while still being a valid topological order for lane assignment.
 *
 * `hasMore` is answered by asking for one commit more than the caller wanted
 * and throwing it away: git stops walking as soon as it has that many, so this
 * costs nothing, whereas `rev-list --count --all` walks the entire DAG on
 * every page.
 */
export async function readLog(
  dir: string,
  limit: number,
  skip: number,
  branchScope: GitBranchScope
): Promise<GitLogResult> {
  // The invocations are independent — git resolves the repository from `dir`
  // exactly as it would from the root, whose value only the result needs —
  // so they run concurrently rather than paying the spawns in sequence.
  const [root, result, head, status] = await Promise.all([
    repoRoot(dir),
    git(dir, [
      'log',
      ...scopeArgs(branchScope),
      '--date-order',
      '--parents',
      `--max-count=${limit + 1}`,
      `--skip=${skip}`,
      `--pretty=format:${LOG_FORMAT}`
    ]),
    readHead(dir),
    // Only the first page asks about the working tree: `loadMore` keeps the
    // list's existing answer, and `status` walks the whole tree and index —
    // the most expensive call here, and the one `Promise.all` would wait on.
    // Submodules are ignored: a submodule pointer that merely drifted from
    // its recorded commit is not a change to *this* repository's own working
    // tree, and would otherwise make the uncommitted-changes row appear for a
    // repo the user did nothing to.
    skip === 0 ? git(dir, ['status', '--porcelain', '--ignore-submodules']) : undefined
  ])
  if (!root.ok) return { ok: false, reason: root.reason }
  // Best-effort: a failed status call (unlikely, given root/log already
  // succeeded) just means "nothing to report" rather than a new failure kind.
  const dirty = status?.ok === true && status.stdout.trim().length > 0
  if (!result.ok) {
    // `log` is where an empty repo fails, so re-aim the failure at the root we
    // did successfully resolve rather than at the directory asked about.
    const reason =
      result.reason.kind === 'no-commits' ? { ...result.reason, root: root.root } : result.reason
    return { ok: false, reason }
  }

  const commits = result.stdout
    .split('\n')
    .filter((line) => line.length > 0)
    .flatMap((line) => {
      const commit = parseLogLine(line)
      return commit ? [commit] : []
    })

  /**
   * An empty repository, detected here rather than from stderr.
   *
   * A bare `git log` in a freshly `git init`ed directory fails with "does not
   * have any commits yet", which `classify` recognizes — but **asking for a
   * ref-reachable log (any of the three scopes) succeeds with empty output
   * instead**, because there is nothing yet for any of them to reach. Measured,
   * after the stderr classification alone silently rendered an empty *list*
   * for an empty repo rather than saying so.
   *
   * Zero commits at the first page means no commit is reachable, which is
   * exactly "no commits yet" — unless the working tree is dirty, in which case
   * there is something real to show (its own row) and reporting a hard
   * failure would hide the very thing the user just did.
   */
  if (skip === 0 && commits.length === 0 && !dirty) {
    return { ok: false, reason: { kind: 'no-commits', root: root.root } }
  }

  const hasMore = commits.length > limit
  return {
    ok: true,
    root: root.root,
    head,
    commits: hasMore ? commits.slice(0, limit) : commits,
    hasMore,
    hasUncommittedChanges: dirty
  }
}

/**
 * `--numstat` lines into changed files.
 *
 * Binary files are reported as `-\t-\t<path>`, which is why the counts are
 * `number | null` rather than defaulting to 0 — "binary" and "changed nothing"
 * are different facts and the panel says which.
 */
function parseNumstat(stdout: string): { files: ChangedFile[]; truncated: boolean } {
  const files: ChangedFile[] = []
  let truncated = false
  for (const line of stdout.split('\n')) {
    if (line.trim().length === 0) continue
    const fields = line.split('\t')
    if (fields.length < 3) continue
    if (files.length >= FILE_CAP) {
      truncated = true
      break
    }
    const [insertions = '', deletions = '', ...pathParts] = fields
    files.push({
      path: pathParts.join('\t'),
      insertions: insertions === '-' ? null : Number.parseInt(insertions, 10),
      deletions: deletions === '-' ? null : Number.parseInt(deletions, 10)
    })
  }
  return { files, truncated }
}

const DETAIL_FORMAT = ['%H', '%P', '%an', '%ae', '%aI', '%D'].join('%x1f')

/**
 * One commit in full.
 *
 * Two invocations rather than one, and deliberately: `%B` (the raw body)
 * contains newlines, so a single `git show --numstat --format=<meta+%B>` would
 * interleave a multi-line field with the line-oriented numstat block and need
 * a parser that guesses where one ends. Asking twice is a few milliseconds and
 * no ambiguity.
 *
 * `-m --first-parent` is what makes this work for every commit shape: a plain
 * `git show --numstat` prints *nothing at all* for a merge (git declines to
 * pick a side), while root commits diff against the empty tree either way.
 * Verified against all three shapes before it was written this way.
 */
export async function readCommit(dir: string, hash: string): Promise<GitCommitResult> {
  // Both invocations run from `dir` — git finds the repository from any
  // directory inside it — and concurrently, since neither needs the other.
  const [meta, numstat] = await Promise.all([
    git(dir, ['show', '--no-patch', `--format=${DETAIL_FORMAT}%x1f%B`, hash]),
    git(dir, ['show', '--numstat', '--format=', '-m', '--first-parent', hash])
  ])
  if (!meta.ok) return { ok: false, reason: meta.reason }

  // The message is the last field, and %B preserves whatever is in it —
  // newlines, and in principle the separator itself — so everything past the
  // sixth separator is message, joined back together.
  const fields = meta.stdout.split(SEP)
  if (fields.length < 7) {
    return { ok: false, reason: { kind: 'failed', message: `Could not read commit ${hash}` } }
  }
  const [fullHash = '', parents = '', author = '', authorEmail = '', date = '', decoration = ''] =
    fields
  const message = fields.slice(6).join(SEP).replace(/\n+$/, '')

  const { files, truncated } = numstat.ok
    ? parseNumstat(numstat.stdout)
    : { files: [], truncated: false }

  return {
    ok: true,
    detail: {
      hash: fullHash,
      parents: parents.length > 0 ? parents.split(' ') : [],
      author,
      authorEmail,
      date,
      refs: parseRefs(decoration),
      message,
      files,
      filesTruncated: truncated
    }
  }
}

/**
 * Paths out of `git status --porcelain`.
 *
 * Each line is two status letters, a separating space, then the path (`XY
 * <path>`, or `XY <old> -> <new>` for a rename) — `line.slice(3)` skips
 * straight past the fixed-width prefix, and only the arrow's right side
 * matters for a rename, since that is the path as it exists on disk now.
 */
function parseStatusPaths(stdout: string): string[] {
  const paths: string[] = []
  for (const line of stdout.split('\n')) {
    if (line.length <= 3) continue
    const rest = line.slice(3)
    const arrow = rest.indexOf(' -> ')
    paths.push(arrow === -1 ? rest : rest.slice(arrow + 4))
  }
  return paths
}

/**
 * One file's stats read directly off disk, for the working-tree files a
 * tracked-diff has nothing to compare against: an untracked file, or (when
 * the repository has no commits at all yet) any file `git status` names.
 * There is no prior version to diff, so "how much changed" is just "how big
 * is the file" — every line is an insertion, never a deletion.
 *
 * Binary detection mirrors git's own heuristic (a NUL byte in the first 8000
 * bytes), so a binary file gets the same `null`/`null` "unknown" the numstat
 * parser already gives one, rather than a byte count masquerading as lines.
 */
async function fileStatsFromDisk(dir: string, relativePath: string): Promise<ChangedFile> {
  try {
    const buffer = await readFile(join(dir, relativePath))
    if (buffer.subarray(0, 8000).includes(0)) {
      return { path: relativePath, insertions: null, deletions: null }
    }
    // Counted on the bytes: a line count needs no decoded string and no
    // per-line array, and an untracked file can be anything up to a dump.
    // A trailing newline ends the last line rather than starting an empty
    // one, which is how git counts too.
    let newlines = 0
    for (let at = buffer.indexOf(0x0a); at !== -1; at = buffer.indexOf(0x0a, at + 1)) newlines++
    const endsWithNewline = buffer.length > 0 && buffer[buffer.length - 1] === 0x0a
    return {
      path: relativePath,
      insertions: endsWithNewline ? newlines : buffer.length === 0 ? 0 : newlines + 1,
      deletions: 0
    }
  } catch {
    // Deleted, permission-denied, or renamed out from under us between the
    // status read and this one — nothing to count, the same "unknown" a
    // binary file gets rather than a false zero.
    return { path: relativePath, insertions: null, deletions: null }
  }
}

/**
 * Everything the working tree's own uncommitted state touched, shaped exactly
 * like a real commit's detail. The renderer's synthetic `Commit` (see
 * `UNCOMMITTED_CHANGES_HASH`) is what makes this selectable through the same
 * mechanism as any real row; this is what answers that selection.
 *
 * Tracked changes — staged and unstaged, combined — come from one
 * `git diff --numstat HEAD`, the same comparison `readLog`'s dirty check is a
 * yes/no version of. Untracked files never appear in that diff (git only
 * diffs what it already knows about), so they are read straight off disk
 * instead (`fileStatsFromDisk`) rather than shelled through git a second time
 * each. When the repository has no commits yet, HEAD does not resolve, so
 * there is no tree to diff against for *any* status entry — every one of them
 * is read the same way as an untracked file, staged or not.
 */
export async function readWorkingTreeChanges(dir: string): Promise<GitCommitResult> {
  // All four at once: the diff needs no answer from the others — with no
  // commits yet it simply fails on the unresolvable HEAD, which is the same
  // "nothing tracked to compare" the fallback below already means.
  const [root, head, status, numstat] = await Promise.all([
    repoRoot(dir),
    git(dir, ['rev-parse', 'HEAD']),
    git(dir, ['status', '--porcelain', '--ignore-submodules']),
    git(dir, ['diff', '--numstat', 'HEAD'])
  ])
  if (!root.ok) return { ok: false, reason: root.reason }

  const hasHead = head.ok
  const tracked = numstat.ok ? parseNumstat(numstat.stdout) : { files: [], truncated: false }
  const trackedPaths = new Set(tracked.files.map((file) => file.path))

  const statusPaths = status.ok ? parseStatusPaths(status.stdout) : []
  const remainingPaths = statusPaths.filter((path) => !trackedPaths.has(path))
  const remainingBudget = Math.max(FILE_CAP - tracked.files.length, 0)
  const extra = await Promise.all(
    remainingPaths.slice(0, remainingBudget).map((path) => fileStatsFromDisk(dir, path))
  )

  return {
    ok: true,
    detail: {
      hash: UNCOMMITTED_CHANGES_HASH,
      parents: hasHead ? [head.stdout.trim()] : [],
      author: '',
      authorEmail: '',
      date: '',
      refs: [],
      message: 'Uncommitted changes',
      files: [...tracked.files, ...extra],
      filesTruncated: tracked.truncated || remainingPaths.length > extra.length
    }
  }
}

/** Whether `dir` is inside a work tree — used only to pick a sensible starting directory. */
export async function isRepo(dir: string): Promise<boolean> {
  return (await repoRoot(dir)).ok
}
