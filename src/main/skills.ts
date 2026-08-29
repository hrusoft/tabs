import { existsSync, lstatSync, mkdirSync, realpathSync, rmSync, symlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { app, ipcMain } from 'electron'
import type { SkillInstallTarget, SkillResult } from '../shared/api'
import { IpcChannel } from '../shared/ipc'

interface SkillInstallTargetDef {
  id: string
  label: string
  /** Where this agent looks for a personal skill — see resources/skills/tabs/SKILL.md. */
  targetDir: () => string
}

/**
 * Every agent this skill can be installed into. Claude Code is the only
 * entry for now; adding another agent later is just adding a row here, not
 * touching installSkill/getSkillStatus.
 */
const TARGETS: SkillInstallTargetDef[] = [
  {
    id: 'claude-code',
    label: 'Claude Code',
    targetDir: () => join(homedir(), '.claude', 'skills', 'tabs')
  }
]

/** Injectable seams so this fs/homedir-touching logic is unit-testable without a real home directory (see terminal.ts's ResolveShellDeps for the same pattern). */
export interface SkillDeps {
  skillsDir?: string
  targets?: SkillInstallTargetDef[]
}

/**
 * Where the bundled skill directory actually lives: packaged builds ship it
 * outside the asar via electron-builder's `extraResources` (a plain OS
 * process — an agent's own shell — can't read into an asar archive at all),
 * dev reads straight from the repo. Mirrors the dev/packaged split used for
 * resources/icon.png in main/windows.ts.
 */
function resolveSkillsDir(override?: string): string {
  if (override) return override
  return app.isPackaged
    ? join(process.resourcesPath, 'skills')
    : join(import.meta.dirname, '../../resources/skills')
}

/** The real path a symlink at `path` resolves to, or undefined if it isn't a symlink (or doesn't exist). */
function existingSymlinkRealTarget(path: string): string | undefined {
  try {
    if (!lstatSync(path).isSymbolicLink()) return undefined
    return realpathSync(path)
  } catch {
    return undefined
  }
}

/**
 * Symlinks the bundled skill into `targetId`'s personal skill directory,
 * creating parent directories as needed. Refuses to touch a destination that
 * already exists and isn't a symlink we previously created ourselves — never
 * clobbers something the user put there.
 */
export function installSkill(
  targetId: string,
  { skillsDir, targets = TARGETS }: SkillDeps = {}
): SkillResult {
  const target = targets.find((t) => t.id === targetId)
  if (!target) return { ok: false, error: `unknown install target: ${targetId}` }

  const source = join(resolveSkillsDir(skillsDir), 'tabs')
  if (!existsSync(source)) return { ok: false, error: 'bundled skill directory not found' }
  const resolvedSource = realpathSync(source)

  const dest = target.targetDir()
  const existingTarget = existingSymlinkRealTarget(dest)
  const destExists = existsSync(dest) || existingTarget !== undefined
  if (destExists && existingTarget !== resolvedSource) {
    return { ok: false, error: `${dest} already exists and isn't managed by Tabs` }
  }

  try {
    if (destExists) rmSync(dest, { force: true })
    mkdirSync(dirname(dest), { recursive: true })
    symlinkSync(source, dest, 'dir')
    return { ok: true }
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) }
  }
}

/**
 * Removes the symlink installSkill created for `targetId`, if any. Same
 * ownership check as installSkill, in reverse: refuses to remove a
 * destination that exists but isn't a symlink (i.e. not something this
 * function's own installSkill created) — never deletes something the user
 * put there themselves. Nothing installed is a no-op, not an error.
 */
export function uninstallSkill(
  targetId: string,
  { targets = TARGETS }: SkillDeps = {}
): SkillResult {
  const target = targets.find((t) => t.id === targetId)
  if (!target) return { ok: false, error: `unknown install target: ${targetId}` }

  const dest = target.targetDir()
  if (existingSymlinkRealTarget(dest) === undefined) {
    if (!existsSync(dest)) return { ok: true }
    return { ok: false, error: `${dest} already exists and isn't managed by Tabs` }
  }

  try {
    rmSync(dest, { force: true })
    return { ok: true }
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) }
  }
}

/** Per-target install status, for the Settings window's AI tab. */
export function getSkillStatus({
  skillsDir,
  targets = TARGETS
}: SkillDeps = {}): SkillInstallTarget[] {
  const source = join(resolveSkillsDir(skillsDir), 'tabs')
  const resolvedSource = existsSync(source) ? realpathSync(source) : undefined
  return targets.map((target) => ({
    id: target.id,
    label: target.label,
    installed:
      resolvedSource !== undefined &&
      existingSymlinkRealTarget(target.targetDir()) === resolvedSource
  }))
}

export function registerSkillsIpc(): void {
  ipcMain.handle(IpcChannel.skillsStatus, () => getSkillStatus())
  ipcMain.handle(IpcChannel.skillsInstall, (_event, targetId: string) => installSkill(targetId))
  ipcMain.handle(IpcChannel.skillsUninstall, (_event, targetId: string) => uninstallSkill(targetId))
}
