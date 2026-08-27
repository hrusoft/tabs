import { existsSync, mkdirSync, mkdtempSync, readlinkSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getSkillStatus, installSkill, uninstallSkill } from '../skills'

describe('installSkill / getSkillStatus', () => {
  let sandbox: string
  let skillsDir: string
  let targetDir: string
  let targets: Array<{ id: string; label: string; targetDir: () => string }>

  // Everything lives under a throwaway tmpdir sandbox — never the real
  // homedir, since installSkill's whole job is symlinking into an agent's
  // personal skill directory and a unit test must not touch the real one.
  beforeEach(() => {
    sandbox = mkdtempSync(join(tmpdir(), 'tabs-skills-test-'))
    skillsDir = join(sandbox, 'bundled-skills')
    mkdirSync(join(skillsDir, 'tabs'), { recursive: true })
    targetDir = join(sandbox, 'agent-home', 'skills', 'tabs')
    targets = [{ id: 'fake-agent', label: 'Fake Agent', targetDir: () => targetDir }]
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
  let targets: Array<{ id: string; label: string; targetDir: () => string }>

  beforeEach(() => {
    sandbox = mkdtempSync(join(tmpdir(), 'tabs-skills-test-'))
    skillsDir = join(sandbox, 'bundled-skills')
    mkdirSync(join(skillsDir, 'tabs'), { recursive: true })
    targetDir = join(sandbox, 'agent-home', 'skills', 'tabs')
    targets = [{ id: 'fake-agent', label: 'Fake Agent', targetDir: () => targetDir }]
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
