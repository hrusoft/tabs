import type { Platform } from '../../src/shared/shortcuts'

/**
 * The platform's primary modifier, in each dialect the suite speaks — stated
 * once per consumer API instead of as an inline ternary per spec file (five
 * files carried four different spellings of the same branch).
 */

const IS_MAC = process.platform === 'darwin'

/** Playwright keyboard chords: `${MOD_KEY}+ArrowLeft`. */
export const MOD_KEY = IS_MAC ? 'Meta' : 'Control'

/** Electron `sendInputEvent`'s modifiers list. */
export const MOD_INPUT_MODIFIER: 'meta' | 'control' = IS_MAC ? 'meta' : 'control'

/** shared/shortcuts' own Platform, for toAccelerator/formatBinding calls in specs. */
export const PLATFORM: Platform = IS_MAC ? 'darwin' : 'other'
