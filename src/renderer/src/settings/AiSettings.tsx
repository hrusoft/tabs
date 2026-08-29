import type { SkillInstallTarget, SkillResult } from '@shared/api'
import { useCallback, useEffect, useRef, useState } from 'react'

/**
 * The "AI" page: what an agent running inside a Tabs pane needs from the app
 * itself. Two things today, and they sit together because they are the same
 * question asked from both ends — what Tabs hands the agent (the bundled
 * "control Tabs" skill, installed into an agent's personal skill directory,
 * see src/main/skills.ts) and what the agent has to be told about Tabs (the
 * bell note below, which is a hint rather than a control: nothing here can
 * write another program's config for it).
 *
 * The install rows are explicit and user-triggered, one per registry target.
 * No generic action row exists in settingsRows.tsx (its SettingRow union is
 * entirely bound to persisted Settings keys, and this isn't one), so this
 * page hand-rolls its markup the way TerminalSettingsPage does for the same
 * reason.
 */
export function AiSettings() {
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
    <div data-testid="settings-page-ai">
      <h1 className="settings-page-title">AI</h1>
      <section className="settings-section">
        <h3 className="settings-section-title">Skills</h3>
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
      <section className="settings-section" data-testid="settings-ai-bell-note">
        <h3 className="settings-section-title">Bell notifications</h3>
        <p className="settings-section-desc">
          Claude Code stays silent in terminals it doesn&apos;t recognise, so it never rings the
          bell (<code className="settings-code">\a</code>) Tabs watches for. Run{' '}
          <code className="settings-code">/config</code> → notification channel → “Terminal bell”,
          or add to <code className="settings-code">~/.claude/settings.json</code>:
        </p>
        <pre className="settings-code-block" data-testid="settings-ai-bell-snippet">
          <code>&quot;preferredNotifChannel&quot;: &quot;terminal_bell&quot;</code>
        </pre>
      </section>
    </div>
  )
}
