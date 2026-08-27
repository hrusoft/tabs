/** The gap every floating overlay keeps between itself and the window edge. */
const OVERLAY_MARGIN = 4

/**
 * Slides an overlay of `size` that would start at `start` fully inside
 * `extent`, keeping `OVERLAY_MARGIN` clear of both edges. Shared by every
 * overlay positioned in JS against the real viewport (the context menu at the
 * cursor, a pane header's hover dropdown over its root button) so they agree
 * on the margin and on what happens when the overlay simply doesn't fit:
 * the near edge wins, since an overlay pushed off the left/top is
 * unreachable in a way one clipped at the right/bottom isn't.
 */
export function clampOverlay(start: number, size: number, extent: number): number {
  return Math.max(OVERLAY_MARGIN, Math.min(start, extent - size - OVERLAY_MARGIN))
}
