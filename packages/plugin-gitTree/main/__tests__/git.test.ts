import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { branchesAtCommit, checkout, readWorkingTreeChanges } from '../git'

// Against a real repository, since what these pin is the shape of git's own
// output — the one thing a fake could not get wrong in the same way.
let repo: string

function git(...args: string[]): void {
  execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], {
    cwd: repo,
    stdio: 'ignore'
  })
}

/** Like `git`, but for a read whose output the test needs (e.g. `rev-parse`). */
function gitOut(...args: string[]): string {
  return execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], {
    cwd: repo
  })
    .toString()
    .trim()
}

async function changedPaths(): Promise<string[]> {
  const result = await readWorkingTreeChanges(repo)
  if (!result.ok) throw new Error(`expected a detail, got ${result.reason.kind}`)
  return result.detail.files.map((file) => file.path).sort()
}

beforeEach(() => {
  repo = mkdtempSync(join(tmpdir(), 'tabs-git-test-'))
  git('init', '-q')
  writeFileSync(join(repo, 'orig.txt'), 'one\ntwo\n')
  git('add', '.')
  git('commit', '-q', '-m', 'initial')
})

afterEach(() => {
  rmSync(repo, { recursive: true, force: true })
})

describe('readWorkingTreeChanges', () => {
  it('names an untracked path with a space verbatim, with its real line count', async () => {
    writeFileSync(join(repo, 'a b.txt'), 'x\ny\nz\n')

    const result = await readWorkingTreeChanges(repo)

    expect(result.ok && result.detail.files).toEqual([
      { path: 'a b.txt', insertions: 3, deletions: 0 }
    ])
  })

  it("lists an untracked directory's files, not the directory", async () => {
    mkdirSync(join(repo, 'd'))
    writeFileSync(join(repo, 'd', 'one.txt'), 'a\n')
    writeFileSync(join(repo, 'd', 'two.txt'), 'b\n')

    expect(await changedPaths()).toEqual(['d/one.txt', 'd/two.txt'])
  })

  it('lists a staged rename once, as the deletion and the new path', async () => {
    git('mv', 'orig.txt', 'renamed.txt')

    expect(await changedPaths()).toEqual(['orig.txt', 'renamed.txt'])
  })
})

// Checking out a commit or branch from the commit list. The initial branch's
// own name is never hardcoded — `git init`'s default depends on the machine's
// `init.defaultBranch` — every test reads it back instead.
describe('branchesAtCommit', () => {
  it('reports the one local branch at the initial commit', async () => {
    const initialBranch = gitOut('rev-parse', '--abbrev-ref', 'HEAD')
    const head = gitOut('rev-parse', 'HEAD')

    const result = await branchesAtCommit(repo, head)

    expect(result.ok && result.local).toEqual([initialBranch])
    expect(result.ok && result.remotes).toEqual([])
    expect(result.ok && result.allLocalBranches).toEqual([initialBranch])
  })

  it('reports every local branch when several point at the same commit', async () => {
    const initialBranch = gitOut('rev-parse', '--abbrev-ref', 'HEAD')
    const head = gitOut('rev-parse', 'HEAD')
    git('branch', 'stable')

    const result = await branchesAtCommit(repo, head)

    expect(result.ok && [...result.local].sort()).toEqual([initialBranch, 'stable'].sort())
  })

  it('reports a commit reachable only through a remote-tracking ref, matched against the real configured remote', async () => {
    git('remote', 'add', 'origin', 'https://example.invalid/repo.git')
    const initialBranch = gitOut('rev-parse', '--abbrev-ref', 'HEAD')
    git('checkout', '-q', '-b', 'feature')
    writeFileSync(join(repo, 'feature.txt'), 'x\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'on feature')
    const featureHead = gitOut('rev-parse', 'HEAD')
    git('update-ref', 'refs/remotes/origin/feature-x', 'feature')
    git('checkout', '-q', initialBranch)
    git('branch', '-D', 'feature')

    const result = await branchesAtCommit(repo, featureHead)

    expect(result.ok && result.local).toEqual([])
    expect(result.ok && result.remotes).toEqual([
      { remote: 'origin', name: 'feature-x', ref: 'origin/feature-x' }
    ])
    expect(result.ok && result.allLocalBranches).toEqual([initialBranch])
  })

  it('excludes refs/remotes/origin/HEAD, the remote symref, as its own fake branch', async () => {
    git('remote', 'add', 'origin', 'https://example.invalid/repo.git')
    const head = gitOut('rev-parse', 'HEAD')
    git('update-ref', 'refs/remotes/origin/main-mirror', head)
    git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main-mirror')

    const result = await branchesAtCommit(repo, head)

    const refs = (result.ok && result.remotes.map((info) => info.ref)) || []
    expect(refs).toContain('origin/main-mirror')
    expect(refs).not.toContain('origin/HEAD')
  })

  it('reports no branch at all for a commit no ref points at', async () => {
    writeFileSync(join(repo, 'orig.txt'), 'one\ntwo\nthree\n')
    git('commit', '-q', '-am', 'second commit')
    const first = gitOut('rev-parse', 'HEAD~1')

    const result = await branchesAtCommit(repo, first)

    expect(result.ok && result.local).toEqual([])
    expect(result.ok && result.remotes).toEqual([])
  })
})

describe('checkout', () => {
  it('switches to a local branch', async () => {
    const initialBranch = gitOut('rev-parse', '--abbrev-ref', 'HEAD')
    git('checkout', '-q', '-b', 'feature')
    writeFileSync(join(repo, 'feature.txt'), 'x\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'on feature')
    git('checkout', '-q', initialBranch)

    const result = await checkout(repo, { kind: 'branch', name: 'feature' })

    expect(result.ok).toBe(true)
    expect(gitOut('rev-parse', '--abbrev-ref', 'HEAD')).toBe('feature')
  })

  it('creates a local tracking branch from a remote-tracking-only ref', async () => {
    git('remote', 'add', 'origin', 'https://example.invalid/repo.git')
    const initialBranch = gitOut('rev-parse', '--abbrev-ref', 'HEAD')
    git('checkout', '-q', '-b', 'feature')
    writeFileSync(join(repo, 'feature.txt'), 'x\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'on feature')
    git('update-ref', 'refs/remotes/origin/feature-x', 'feature')
    git('checkout', '-q', initialBranch)
    git('branch', '-D', 'feature')

    const result = await checkout(repo, {
      kind: 'remote-branch',
      remote: 'origin',
      name: 'feature-x',
      ref: 'origin/feature-x'
    })

    expect(result.ok).toBe(true)
    expect(gitOut('rev-parse', '--abbrev-ref', 'HEAD')).toBe('feature-x')
    expect(gitOut('rev-parse', '--abbrev-ref', 'feature-x@{u}')).toBe('origin/feature-x')
  })

  it('detaches HEAD at a bare commit hash', async () => {
    writeFileSync(join(repo, 'orig.txt'), 'one\ntwo\nthree\n')
    git('commit', '-q', '-am', 'second commit')
    const first = gitOut('rev-parse', 'HEAD~1')

    const result = await checkout(repo, { kind: 'commit', hash: first })

    expect(result.ok).toBe(true)
    expect(gitOut('rev-parse', 'HEAD')).toBe(first)
    expect(() => gitOut('symbolic-ref', '-q', 'HEAD')).toThrow()
  })

  it('refuses a checkout that would overwrite uncommitted changes, leaves HEAD untouched, and keeps the full refusal text', async () => {
    const initialBranch = gitOut('rev-parse', '--abbrev-ref', 'HEAD')
    git('checkout', '-q', '-b', 'feature')
    writeFileSync(join(repo, 'orig.txt'), 'one\ntwo\non feature\n')
    git('commit', '-q', '-am', 'diverge on feature')
    git('checkout', '-q', initialBranch)
    // Dirty the same file so switching to `feature` would overwrite it.
    writeFileSync(join(repo, 'orig.txt'), 'one\ntwo\nlocal edit, uncommitted\n')

    const result = await checkout(repo, { kind: 'branch', name: 'feature' })

    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('expected a refusal')
    expect(result.reason.kind).toBe('failed')
    // The one-line `reason.message` alone would lose the file list and the
    // "commit or stash" guidance — `detail` is what keeps the whole thing.
    expect(result.detail).toContain('overwritten by checkout')
    expect(result.detail).toContain('orig.txt')
    expect(result.detail).toContain('Please commit your changes or stash them')
    // Untouched: still on the original branch, with the dirty edit intact.
    expect(gitOut('rev-parse', '--abbrev-ref', 'HEAD')).toBe(initialBranch)
    expect(readFileSync(join(repo, 'orig.txt'), 'utf8')).toContain('local edit, uncommitted')
  })

  it('refuses to create a tracking branch whose name collides with an existing local branch elsewhere — the real behavior decideCheckout filters around', async () => {
    git('remote', 'add', 'origin', 'https://example.invalid/repo.git')
    git('update-ref', 'refs/remotes/origin/feature', gitOut('rev-parse', 'HEAD'))
    // A local `feature` branch exists (elsewhere, not at the commit in
    // question) — the everyday "my local is behind its remote" shape.
    git('branch', 'feature')

    const result = await checkout(repo, {
      kind: 'remote-branch',
      remote: 'origin',
      name: 'feature',
      ref: 'origin/feature'
    })

    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('expected a refusal')
    expect(result.detail).toContain("a branch named 'feature' already exists")
  })
})
