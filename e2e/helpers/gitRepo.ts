import { execFileSync } from 'node:child_process'
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

/**
 * Real repositories on disk, built per test, for the one spec whose subject is
 * the git integration itself.
 *
 * Created rather than committed as a fixture: a `.git` directory inside this
 * repository is a nested-repo mess that every tool here would have to be told
 * about, and `git init` plus four commits costs about 30ms. Everything that
 * makes a hash — author, committer, dates — is pinned, so the graph is
 * identical on every machine and every run.
 *
 * Synchronous on purpose: this runs in the Playwright worker, not in the app,
 * so none of the shutdown hazards around spawning processes from the main
 * process apply.
 */

/**
 * Every directory made here, so a spec can drop them all in one call. Module
 * scope is safe for the same reason launch.ts's own `launched` registry is:
 * a Playwright worker runs one spec file at a time, so this is per-file state.
 */
const created: string[] = []

/**
 * A fresh temp directory, by its **resolved** path.
 *
 * `realpathSync` is not tidiness. On macOS `/var` is a symlink to
 * `/private/var`, so `mkdtempSync(tmpdir())` hands back the `/var/...` form
 * while anything that asks the OS where a process actually is — `lsof`, which
 * is how a terminal's live cwd is read — answers with `/private/var/...`. A
 * test comparing an inherited directory against the unresolved form fails
 * against a feature that worked perfectly, which is exactly how this was
 * found. Resolving once here keeps every path in these tests the one the OS
 * will report.
 */
function makeDir(prefix: string): string {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), prefix)))
  created.push(dir)
  return dir
}

/** Fixed identity and dates, so hashes and ordering never depend on the machine or the clock. */
function gitEnv(date: string): NodeJS.ProcessEnv {
  return {
    ...process.env,
    GIT_AUTHOR_NAME: 'Ann Example',
    GIT_AUTHOR_EMAIL: 'ann@example.com',
    GIT_COMMITTER_NAME: 'Ann Example',
    GIT_COMMITTER_EMAIL: 'ann@example.com',
    GIT_AUTHOR_DATE: date,
    GIT_COMMITTER_DATE: date
  }
}

function git(cwd: string, args: string[], date = '2026-01-01T00:00:00+00:00'): void {
  execFileSync('git', args, { cwd, env: gitEnv(date), stdio: 'pipe' })
}

/** A directory that is not a repository at all. */
export function createPlainDirectory(): string {
  return makeDir('tabs-e2e-plain-')
}

/** A repository with no commits — `rev-parse` succeeds there, `log` does not. */
export function createEmptyRepo(): string {
  const dir = makeDir('tabs-e2e-emptyrepo-')
  git(dir, ['init', '-q', '-b', 'main'])
  return dir
}

/**
 * A repository with a known four-commit graph containing one real merge:
 *
 *     merge feature   <- main, HEAD
 *     |\
 *     | on feature    <- feature
 *     on main
 *     |/
 *     root commit
 *
 * Dates ascend so `--date-order` puts them in exactly the order above, and the
 * merge is `--no-ff` so it genuinely has two parents — which is what makes the
 * gutter two lanes wide rather than one.
 */
export function createRepoWithMerge(): string {
  const dir = makeDir('tabs-e2e-repo-')
  git(dir, ['init', '-q', '-b', 'main'])

  writeFileSync(path.join(dir, 'root.txt'), 'root\n')
  git(dir, ['add', '-A'], '2026-01-01T00:00:00+00:00')
  git(dir, ['commit', '-q', '-m', 'root commit'], '2026-01-01T00:00:00+00:00')

  git(dir, ['checkout', '-q', '-b', 'feature'])
  writeFileSync(path.join(dir, 'feature.txt'), 'feature\n')
  git(dir, ['add', '-A'], '2026-01-02T00:00:00+00:00')
  git(dir, ['commit', '-q', '-m', 'on feature'], '2026-01-02T00:00:00+00:00')

  git(dir, ['checkout', '-q', 'main'])
  writeFileSync(path.join(dir, 'main.txt'), 'main\nsecond line\n')
  git(dir, ['add', '-A'], '2026-01-03T00:00:00+00:00')
  git(dir, ['commit', '-q', '-m', 'on main'], '2026-01-03T00:00:00+00:00')

  git(
    dir,
    ['merge', '-q', '--no-ff', 'feature', '-m', 'merge feature'],
    '2026-01-04T00:00:00+00:00'
  )
  return dir
}

/** Deletes every directory made here. Call from a spec's afterAll. */
export function removeTestRepos(): void {
  for (const dir of created.splice(0)) rmSync(dir, { recursive: true, force: true })
}
