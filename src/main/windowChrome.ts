/**
 * macOS rounds a standard titled window's corners in the WindowServer
 * compositor, outside the app's own layer tree — there is no public AppKit or
 * Core Graphics call that hands the radius back (see CLAUDE.md's "how do I
 * find the curvature" entry). The active-pane outline (`--pane-corner-radius`
 * in global.css) needs a number anyway, so this is a hand-measured table
 * keyed by macOS major version — the same approach window-border tools like
 * FelixKratz's JankyBorders use for the identical problem of drawing an
 * accent outline that has to sweep into a corner it cannot query.
 *
 * Keyed by `process.getSystemVersion()`'s marketing version string ("15.5",
 * "26.6.2") — Electron's own note on that call is the reason it's used
 * instead of `os.release()`: the latter returns the Darwin kernel version,
 * not the macOS one.
 */
const KNOWN_RADII: Record<number, number> = {
  // Big Sur through Sequoia: a consistently cited/reverse-engineered value
  // across that whole redesign era (a "continuous"/squircle curve, not a
  // circular arc — CSS border-radius only approximates it, closely enough at
  // this size that the seam it's fixing disappears).
  11: 10,
  12: 10,
  13: 10,
  14: 10,
  15: 10,
  // Tahoe's Liquid Glass redesign visibly increased corner radii across
  // system chrome (buttons, sheets, windows all got rounder). UNVERIFIED for
  // the window frame specifically — measuring it needs a real screenshot of
  // the composited window, and screen-capture access wasn't available when
  // this table was written. Treat as a starting point, not a measured fact,
  // until someone confirms it by eye against a real corner.
  26: 16
}

const FALLBACK_RADIUS = 10

const LATEST_KNOWN_MAJOR = Math.max(...Object.keys(KNOWN_RADII).map(Number))

/** Pure lookup, unit-testable without Electron. */
export function macWindowCornerRadius(systemVersion: string): number {
  const major = Number.parseInt(systemVersion.split('.')[0] ?? '', 10)
  if (Number.isNaN(major)) return FALLBACK_RADIUS
  const known = KNOWN_RADII[major]
  if (known !== undefined) return known
  // A version newer than anything measured: assume it kept the most recent
  // known value rather than reverting to the pre-redesign one.
  return major > LATEST_KNOWN_MAJOR ? KNOWN_RADII[LATEST_KNOWN_MAJOR]! : FALLBACK_RADIUS
}

/** 0 on non-macOS platforms, where this rounding doesn't apply. */
export function currentWindowCornerRadius(): number {
  if (process.platform !== 'darwin') return 0
  return macWindowCornerRadius(process.getSystemVersion())
}
