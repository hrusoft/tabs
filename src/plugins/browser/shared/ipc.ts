/**
 * The browser package's bridge vocabulary. Renderer→main methods (the
 * guest-attachment reports the guest registry is built from, plus
 * createBrowserPane's early ownership report) and main→renderer events (the
 * guest signals a `<webview>` structurally cannot deliver as DOM events — see
 * the renderer's guestNavKeys.ts and guestActivation.ts). Channel strings are
 * derived by the generic bridge (`plugin:browser:…`, see shared/plugin/bridge.ts).
 */
export const BrowserGuestMethod = {
  attached: 'guest-attached',
  detached: 'guest-detached'
} as const

export const BrowserGuestEvent = {
  navKey: 'guest-nav-key',
  pointerDown: 'guest-pointer-down'
} as const

/**
 * Reports a pane's id and its owner the instant createBrowserPane's
 * placeNewPane runs — well before that verb's relay resolves, which is what
 * left an agent-owned pane's popup-deny and scheme-allowlist guards unarmed
 * for the whole mount/load wait (see main/browserExternalControl.ts's
 * registerBrowserControlVerbs and renderer/browserExternalControl.ts's
 * handleCreateBrowserPane).
 */
export const BrowserMethod = {
  paneCreated: 'pane-created'
} as const
