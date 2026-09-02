import { existsSync, mkdirSync, mkdtempSync, readlinkSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getSkillStatus, installSkill, uninstallSkill } from '../skills'

type Target = { id: string; label: string; targetDir: () => string }

interface Sandbox {
  sandbox: string
  skillsDir: string
  /** One per requested agent, in order — the directory each target symlinks into. */
  targetDirs: string[]
  targets: Target[]
}

/**
 * Everything lives under a throwaway tmpdir sandbox — never the real homedir,
 * since installSkill's whole job is symlinking into an agent's personal skill
 * directory and a unit test must not touch the real one. One fake agent per
 * name given; each gets its own home under the sandbox.
 */
function makeSandbox(agents: Array<{ id: string; label: string }>): Sandbox {
  const sandbox = mkdtempSync(join(tmpdir(), 'tabs-skills-test-'))
  const skillsDir = join(sandbox, 'bundled-skills')
  mkdirSync(join(skillsDir, 'tabs'), { recursive: true })
  const targetDirs = agents.map((agent) => join(sandbox, `${agent.id}-home`, 'skills', 'tabs'))
  const targets = agents.map((agent, index) => ({ ...agent, targetDir: () => targetDirs[index]! }))
  return { sandbox, skillsDir, targetDirs, targets }
}

const FAKE_AGENT = { id: 'fake-agent', label: 'Fake Agent' }

describe('installSkill / getSkillStatus', () => {
  let sandbox: string
  let skillsDir: string
  let targetDir: string
  let targets: Target[]

  beforeEach(() => {
    const made = makeSandbox([FAKE_AGENT])
    sandbox = made.sandbox
    skillsDir = made.skillsDir
    targetDir = made.targetDirs[0]!
    targets = made.targets
  })

  afterEach(() => {
    rmSync(sandbox, { recursive: true, force: true })
  })

  it('reports not installed before installing', () => {
    expect(getSkillStatus({ skillsDir, targets })).toEqual([
      { id: 'fake-agent', label: 'Fake Agent', installed: false }
    ])
  })

  it('symlinks the bundled skill into the target directory', () => {
    const result = installSkill('fake-agent', { skillsDir, targets })
    expect(result).toEqual({ ok: true })
    expect(readlinkSync(targetDir)).toBe(join(skillsDir, 'tabs'))
  })

  it('reports installed after installing', () => {
    installSkill('fake-agent', { skillsDir, targets })
    expect(getSkillStatus({ skillsDir, targets })).toEqual([
      { id: 'fake-agent', label: 'Fake Agent', installed: true }
    ])
  })

  it('is idempotent — installing twice succeeds and re-links cleanly', () => {
    expect(installSkill('fake-agent', { skillsDir, targets })).toEqual({ ok: true })
    expect(installSkill('fake-agent', { skillsDir, targets })).toEqual({ ok: true })
    expect(readlinkSync(targetDir)).toBe(join(skillsDir, 'tabs'))
  })

  it('refuses to clobber a destination that already exists and is not ours', () => {
    mkdirSync(targetDir, { recursive: true })
    writeFileSync(join(targetDir, 'SKILL.md'), 'not ours')
    const result = installSkill('fake-agent', { skillsDir, targets })
    expect(result.ok).toBe(false)
  })

  it('errors on an unknown target id', () => {
    expect(installSkill('nonexistent', { skillsDir, targets })).toEqual({
      ok: false,
      error: 'unknown install target: nonexistent'
    })
  })

  it('errors when the bundled skill directory is missing', () => {
    expect(installSkill('fake-agent', { skillsDir: join(sandbox, 'missing'), targets })).toEqual({
      ok: false,
      error: 'bundled skill directory not found'
    })
  })
})

describe('uninstallSkill', () => {
  let sandbox: string
  let skillsDir: string
  let targetDir: string
  let targets: Target[]

  beforeEach(() => {
    const made = makeSandbox([FAKE_AGENT])
    sandbox = made.sandbox
    skillsDir = made.skillsDir
    targetDir = made.targetDirs[0]!
    targets = made.targets
  })

  afterEach(() => {
    rmSync(sandbox, { recursive: true, force: true })
  })

  it('removes a symlink installSkill created', () => {
    installSkill('fake-agent', { skillsDir, targets })
    expect(uninstallSkill('fake-agent', { targets })).toEqual({ ok: true })
    expect(existsSync(targetDir)).toBe(false)
  })

  it('reports not installed after uninstalling', () => {
    installSkill('fake-agent', { skillsDir, targets })
    uninstallSkill('fake-agent', { targets })
    expect(getSkillStatus({ skillsDir, targets })).toEqual([
      { id: 'fake-agent', label: 'Fake Agent', installed: false }
    ])
  })

  it('is a no-op when nothing is installed', () => {
    expect(uninstallSkill('fake-agent', { targets })).toEqual({ ok: true })
  })

  it('refuses to remove a destination that exists but is not a symlink we created', () => {
    mkdirSync(targetDir, { recursive: true })
    writeFileSync(join(targetDir, 'SKILL.md'), 'not ours')
    const result = uninstallSkill('fake-agent', { targets })
    expect(result.ok).toBe(false)
    expect(existsSync(targetDir)).toBe(true)
  })

  it('errors on an unknown target id', () => {
    expect(uninstallSkill('nonexistent', { targets })).toEqual({
      ok: false,
      error: 'unknown install target: nonexistent'
    })
  })
})

// Coverage for the shape TARGETS now actually has: more than one agent.
// Nothing above ever exercises a list with two entries, so nothing above
// would have caught one target's install/uninstall leaking into another's.
describe('multiple install targets', () => {
  let sandbox: string
  let skillsDir: string
  let targetDirA: string
  let targetDirB: string
  let targets: Target[]

  beforeEach(() => {
    const made = makeSandbox([
      { id: 'agent-a', label: 'Agent A' },
      { id: 'agent-b', label: 'Agent B' }
    ])
    sandbox = made.sandbox
    skillsDir = made.skillsDir
    ;[targetDirA, targetDirB] = made.targetDirs as [string, string]
    targets = made.targets
  })

  afterEach(() => {
    rmSync(sandbox, { recursive: true, force: true })
  })

  it('reports independent not-installed status for each target', () => {
    expect(getSkillStatus({ skillsDir, targets })).toEqual([
      { id: 'agent-a', label: 'Agent A', installed: false },
      { id: 'agent-b', label: 'Agent B', installed: false }
    ])
  })

  it('installing one target does not install the other', () => {
    expect(installSkill('agent-a', { skillsDir, targets })).toEqual({ ok: true })
    expect(getSkillStatus({ skillsDir, targets })).toEqual([
      { id: 'agent-a', label: 'Agent A', installed: true },
      { id: 'agent-b', label: 'Agent B', installed: false }
    ])
    expect(existsSync(targetDirB)).toBe(false)
  })

  it('installing both targets symlinks each into its own directory, sharing one bundled source', () => {
    expect(installSkill('agent-a', { skillsDir, targets })).toEqual({ ok: true })
    expect(installSkill('agent-b', { skillsDir, targets })).toEqual({ ok: true })
    expect(readlinkSync(targetDirA)).toBe(join(skillsDir, 'tabs'))
    expect(readlinkSync(targetDirB)).toBe(join(skillsDir, 'tabs'))
    expect(getSkillStatus({ skillsDir, targets })).toEqual([
      { id: 'agent-a', label: 'Agent A', installed: true },
      { id: 'agent-b', label: 'Agent B', installed: true }
    ])
  })

  it('uninstalling one target leaves the other installed', () => {
    installSkill('agent-a', { skillsDir, targets })
    installSkill('agent-b', { skillsDir, targets })
    expect(uninstallSkill('agent-a', { targets })).toEqual({ ok: true })
    expect(existsSync(targetDirA)).toBe(false)
    expect(getSkillStatus({ skillsDir, targets })).toEqual([
      { id: 'agent-a', label: 'Agent A', installed: false },
      { id: 'agent-b', label: 'Agent B', installed: true }
    ])
  })
})
