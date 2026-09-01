/**
 * Feeds `--pane-corner-radius` (global.css) with the OS-applied rounding of
 * the window's own corners, before the first frame — the same
 * before-createRoot, module-scope contract as installTheme(), and for the
 * same reason: an async fetch here would flash a sharp corner against the
 * window's rounded one for a frame. The number itself comes from a
 * hand-measured table in main (windowChrome.ts) — there is no live query for
 * a window's own corner radius, on either side of the IPC boundary.
 *
 * Call this once, at module scope, in an entry point that actually renders a
 * pane tree (main.tsx). The Settings/About windows have no active-pane
 * outline to round.
 */
export function installWindowChrome(): void {
  const radius = window.api.appWindow.getCornerRadiusSync()
  document.documentElement.style.setProperty('--os-corner-radius', `${radius}px`)
}
