import { fireAndReport } from '../content/fireAndReport'
import { openCaffeinateDialog } from './CaffeinateDialog'
import { useCaffeinateStore } from './caffeinateStore'

/**
 * Wires the pane-tree renderer's half of the caffeinate feature: keeps
 * caffeinateStore's `running` flag live, and opens the dialog whenever
 * File → Caffeinate… forwards `caffeinate:open-dialog` (main answers Decaf
 * itself, directly, with no renderer involved at all — see main/menu.ts).
 * Called once, at module scope, before the first render — for the life of
 * the page, so there is nothing to uninstall. main.tsx's comment says why it
 * can't wait for an effect.
 */
export function installCaffeinate(): void {
  window.api.caffeinate.onRunningChanged((running) => {
    useCaffeinateStore.getState().setRunning(running)
  })
  window.api.caffeinate.onOpenDialog(() => {
    fireAndReport(async () => {
      const flags = await openCaffeinateDialog()
      if (flags) window.api.caffeinate.start(flags)
    })
  })
}
