import type { SkillInstallTarget, SkillResult } from '@shared/api'
import { useCallback, useEffect, useRef, useState } from 'react'

/**
 * Installs (or uninstalls) the bundled "control Tabs" skill into an agent's
 * personal skill directory (see src/main/skills.ts) — explicit, user-
 * triggered, one row per registry target. No generic action row exists in
 * settingsRows.tsx (its SettingRow union is entirely bound to persisted
 * Settings keys, and this isn't one), so this page hand-rolls its markup the
 * way TerminalSettingsPage does for the same reason.
 */
export function SkillsSettings() {
  const [targets, setTargets] = useState<SkillInstallTarget[] | null>(null)
  const [busy, setBusy] = useState<Record<string, boolean>>({})
  const [errors, setErrors] = useState<Record<string, string>>({})

  // Sequenced so a slow status answer can't overwrite a newer one — two
  // installs run back-to-back across rows would otherwise race their
  // refreshes and could paint the stale target list last. (useIsFullScreen's
  // sawChange is the same guard with a boolean, since there the race is one
  // pull against pushes rather than pull against pull.)
  const statusSeq = useRef(0)
  const refreshTargets = useCallback((): void => {
    const seq = ++statusSeq.current
    window.api.skills.status().then((next) => {
      if (seq === statusSeq.current) setTargets(next)
    })
  }, [])

  useEffect(() => {
    refreshTargets()
  }, [refreshTargets])

  const run = async (
    targetId: string,
    call: (targetId: string) => Promise<SkillResult>
  ): Promise<void> => {
    setBusy((state) => ({ ...state, [targetId]: true }))
    const result = await call(targetId)
    setBusy((state) => ({ ...state, [targetId]: false }))
    if (result.ok) {
      setErrors((prev) => ({ ...prev, [targetId]: '' }))
      refreshTargets()
    } else {
      setErrors((prev) => ({ ...prev, [targetId]: result.error }))
    }
  }

  return (
    <div data-testid="settings-page-skills">
      <h1 className="settings-page-title">Skills</h1>
      <section className="settings-section">
        <p className="settings-section-desc">
          Installs a skill that lets an agent running in a Tabs terminal pane open and control
          browser panes it creates. It only works from inside Tabs — installing it doesn't affect
          anything outside the app.
        </p>
        {targets === null && <p className="settings-row-desc">Loading…</p>}
        {targets?.map((target) => {
          const targetBusy = busy[target.id] ?? false
          const error = errors[target.id]
          return (
            <div key={target.id} className="settings-row settings-row-action">
              <span className="settings-row-text">
                <span className="settings-row-title">{target.label}</span>
                <span className="settings-row-desc">
                  {error || (target.installed ? 'Installed' : 'Not installed')}
                </span>
              </span>
              <span className="settings-row-buttons">
                <button
                  type="button"
                  className="settings-secondary-button"
                  data-testid={`settings-skill-install-${target.id}`}
                  disabled={targetBusy}
                  onClick={() => run(target.id, window.api.skills.install)}
                >
                  {target.installed ? 'Reinstall' : 'Install'}
                </button>
                {target.installed && (
                  <button
                    type="button"
                    className="settings-secondary-button"
                    data-testid={`settings-skill-uninstall-${target.id}`}
                    disabled={targetBusy}
                    onClick={() => run(target.id, window.api.skills.uninstall)}
                  >
                    Uninstall
                  </button>
                )}
              </span>
            </div>
          )
        })}
      </section>
    </div>
  )
}
