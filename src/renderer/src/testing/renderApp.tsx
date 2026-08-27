import { createLeaf } from '@shared/model/factories'
import { type ContentNode, EMPTY_TYPE } from '@shared/model/types'
import { DEFAULT_SETTINGS, type Settings } from '@shared/settings'
import { type RenderResult, render } from '@testing-library/react'
import { StrictMode } from 'react'
import App from '../App'
import { resetUnpinMemoryForTests } from '../content/floating/unpin'
import { useBellStore } from '../core/store/bellStore'
import { useCommandPaletteStore } from '../core/store/commandPaletteStore'
import { useContextMenuStore } from '../core/store/contextMenuStore'
import { useControlStore } from '../core/store/controlStore'
import { useDragStore } from '../core/store/dragStore'
import { repairDockedRoot, useLayoutStore } from '../core/store/layoutStore'
import { useNavFlashStore } from '../core/store/navFlashStore'
import { useSettingsStore } from '../core/store/settingsStore'
import { registerTestContent } from './registerTestContent'

/**
 * Puts every store singleton back to a known starting state — the jsdom
 * tier's equivalent of the Electron tier's renderer reload. Partial setState
 * merges, so store actions survive; module-level wiring (the persist
 * subscription, settings onChange) is per-process state the real renderer
 * also keeps for its lifetime, so it stays too.
 */
// Anything new that holds renderer store state needs a reset added here or it
// silently leaks into the next jsdom test — the same rule main/e2e.ts's reset
// states for main-process state. The list is currently every `create<...>` in
// core/store.
function resetStores(root?: ContentNode, settings?: Partial<Settings>): void {
  window.__fakeApi?.reset({ settings })
  // Seeded roots go through the same repair as every real boot path
  // (`repairDockedRoot`, which loadInitialState also uses): the running
  // app's docked root is always a tab group, so a test that skips this
  // starts from a shape the app can never actually be in.
  useLayoutStore.setState({
    ...repairDockedRoot(root ?? createLeaf(EMPTY_TYPE)),
    floating: []
  })
  useSettingsStore.setState({ ...DEFAULT_SETTINGS, ...settings })
  useContextMenuStore.setState({ menu: null })
  useDragStore.setState({ drag: null })
  useNavFlashStore.setState({ flash: null })
  useBellStore.setState({ ringing: new Set() })
  useControlStore.setState({ controlled: new Set() })
  useCommandPaletteStore.setState({ step: { kind: 'closed' } })
  // Module-level, not a store, but per-test state all the same: where each
  // pane's floating window last sat (floating/unpin.ts).
  resetUnpinMemoryForTests()
}

/**
 * Mounts the real <App/> for a component test: stub content registry, fresh
 * store state, StrictMode for production fidelity (main.tsx mounts the same
 * way). The fake bridge is already installed by vitest.setup.ts; script it
 * through window.__fakeApi.
 */
export function renderApp(
  opts: { root?: ContentNode; settings?: Partial<Settings> } = {}
): RenderResult {
  registerTestContent()
  resetStores(opts.root, opts.settings)
  return render(
    <StrictMode>
      <App />
    </StrictMode>
  )
}
