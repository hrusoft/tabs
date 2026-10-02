/**
 * The `config` key a leaf's captured visual state travels under while it
 * crosses windows (see `PaneCapabilities.captureTransferState`). Transient:
 * written on detach, consumed at the destination's mount, never persisted —
 * it can hold a terminal's scrollback. Split out of
 * `src/shared/layoutCrossWindow.ts` (which stays core-owned — the rest of
 * that module is the main<->renderer cross-window drag protocol, not
 * plugin-facing) since this one constant is the only thing a content type
 * actually needs: `PaneCapabilities.captureTransferState`'s implementer
 * writes its snapshot onto the leaf's config under this exact key.
 */
export const CROSS_WINDOW_TRANSFER_STATE_KEY = 'crossWindowTransferState'
