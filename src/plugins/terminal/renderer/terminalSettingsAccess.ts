import { createTypedSettingsAccess } from '../../../renderer/src/plugin/api'
import { DEFAULT_TERMINAL_SETTINGS, type TerminalSettings } from '../shared/settings'

/**
 * The terminal's typed view of its settings blob — see createTypedSettingsAccess
 * for what the factory holds and why the narrowing cast inside it is sound.
 * Named exports rather than the object itself so `use` keeps a `use*` name and
 * reads as the hook it is at every call site.
 */
const access = createTypedSettingsAccess<TerminalSettings>('terminal', DEFAULT_TERMINAL_SETTINGS)

export const installTerminalSettingsAccess = access.install
export const getTerminalSettings = access.get
export const useTerminalSetting = access.use
export const updateTerminalSettings = access.update
