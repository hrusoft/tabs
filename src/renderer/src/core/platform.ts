import type { Platform } from '@shared/shortcuts'

/**
 * Which platform's modifier conventions this renderer follows — one const for
 * the whole process, not one per consumer.
 *
 * Both sides of a rebindable shortcut read it: the Settings capture field
 * records a combination in these terms (KeyboardSettings.tsx), and the keydown
 * enforcer matches against them (content/spatialNav.ts). Two copies that
 * disagreed would let a user record a combination that could never fire.
 *
 * `navigator.platform` is deprecated but is the only synchronous answer here —
 * `userAgentData` is async and Chromium-only-with-a-flag — and this needs to be
 * settled at module scope, before the first keydown or the first render.
 */
export const platform: Platform = navigator.platform.startsWith('Mac') ? 'darwin' : 'other'
