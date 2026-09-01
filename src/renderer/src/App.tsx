import { useEffect } from 'react'
import { ContextMenu } from './ContextMenu'
import { CommandPalette } from './content/CommandPalette'
import { ContentView } from './content/ContentView'
import { installExternalControl } from './content/externalControl'
import { FloatingLayer } from './content/floating/FloatingLayer'
import { NavFlashOverlay } from './content/NavFlashOverlay'
import { installPaneShortcuts } from './content/paneShortcuts'
import { installSpatialNav } from './content/spatialNav'
import { DragOverlay } from './content/tabs/DragOverlay'
import { PaneFocusFollower } from './core/registry/paneHandles'
import { useLayoutStore } from './core/store/layoutStore'
import { useIsFullScreen } from './useIsFullScreen'

/**
 * The window has no chrome of its own any more — the docked root is always a
 * tab group (see `ensureTabsRoot`), and that group's own tab bar doubles as
 * the window's title bar: drag handle, traffic-light gutter and the Settings
 * button all live there now (TabBar.tsx), gated on `state.root.id` rather
 * than on anything App.tsx knows about. Fullscreen — the one window-level
 * state that bar's chrome depends on, since macOS hides the traffic lights
 * there — is published once here as `data-fullscreen` on the shell, and the
 * stylesheet does the rest (see `.app-shell:not([data-fullscreen])` rules in
 * global.css): no component in the tree reads it, so the DOM change is
 * confined to this one attribute (App itself re-renders, and the memoized
 * content tree bails).
 */
export default function App() {
  const root = useLayoutStore((state) => state.root)
  const isFullScreen = useIsFullScreen()
  useEffect(() => installSpatialNav(), [])
  useEffect(() => installPaneShortcuts(), [])
  useEffect(() => installExternalControl(), [])
  return (
    <div className="app-shell" data-fullscreen={isFullScreen || undefined}>
      <div className="app-content">
        {/* The docked root always touches both of the window's true bottom
            corners — it *is* the window, below the title bar — except in
            fullscreen, where macOS gives the window square corners
            edge-to-edge. See ContentRendererProps.cornerLeft/cornerRight and
            SplitRenderer for how this fans out to whichever leaf actually
            ends up there. */}
        <ContentView node={root} cornerLeft={!isFullScreen} cornerRight={!isFullScreen} />
      </div>
      <FloatingLayer />
      <DragOverlay />
      <NavFlashOverlay />
      <ContextMenu />
      <CommandPalette />
      {/* Renders nothing; last so its layout effect — which hands the
          keyboard to whichever pane just became active — runs after every
          other effect in the commit. */}
      <PaneFocusFollower />
    </div>
  )
}
