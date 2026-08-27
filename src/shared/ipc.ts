/**
 * Every *core* IPC channel name used between main and preload, in one place so
 * the two sides can't drift apart. Renderer code never sees these — it talks to
 * `window.api`, which preload builds from them.
 *
 * A content type's channels live with the type, in
 * `src/plugins/<type>/shared/ipc.ts`, and are not re-exported here: this object
 * is what core owns, and a type's channel count is nobody else's business.
 * `bellRing` and `fontsListFamilies` stay here despite having a single
 * terminal-side caller each, because their `window.api` namespaces are core by
 * decision — a channel belongs with its namespace.
 */
export const IpcChannel = {
  paneConfirmClose: 'pane:confirmClose',
  settingsGetSync: 'settings:get-sync',
  settingsSet: 'settings:set',
  layoutGetSync: 'layout:get-sync',
  layoutSet: 'layout:set',
  bellRing: 'bell:ring',
  fontsListFamilies: 'fonts:list-families',
  windowIsFullScreen: 'window:is-fullscreen',
  windowFullScreenChanged: 'window:fullscreen-changed',
  windowOpenSettings: 'window:open-settings',
  windowOpenExternal: 'window:open-external',
  /**
   * The About window's identity block, read synchronously so the version is
   * present in its first painted frame rather than arriving a tick later —
   * the same rule the layout and settings reads follow.
   */
  windowGetAppInfoSync: 'window:get-app-info-sync',
  /**
   * Writes to the user's system clipboard, from main rather than the
   * renderer. `navigator.clipboard` needs a focused document, which the
   * e2e window never genuinely is (see e2eHidden.ts), and Electron's own
   * clipboard module has no such requirement — so the About window's
   * copy-address buttons work identically in both.
   */
  windowCopyText: 'window:copy-text',
  settingsChanged: 'settings:changed',
  /**
   * One channel for every menu-forwarded shortcut, carrying the
   * `ShortcutActionId` that fired rather than encoding it in the channel name.
   * A per-action channel would make every new shortcut a hand-synced edit
   * across the bridge's layers, carrying no information beyond the id — see
   * shortcuts.onShortcut in src/shared/api.ts.
   */
  shortcutAction: 'shortcut:action',
  shortcutsSetCapture: 'shortcuts:set-capture',
  externalControlRequest: 'external-control:request',
  externalControlResponse: 'external-control:response',
  externalControlOwnershipGetSync: 'external-control:ownership-get-sync',
  externalControlOwnershipChanged: 'external-control:ownership-changed',
  skillsStatus: 'skills:status',
  skillsInstall: 'skills:install',
  skillsUninstall: 'skills:uninstall'
} as const
