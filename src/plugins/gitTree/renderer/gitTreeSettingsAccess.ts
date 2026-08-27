import { createTypedSettingsAccess } from '../../../renderer/src/plugin/api'
import { DEFAULT_GIT_TREE_SETTINGS, type GitTreeSettings } from '../shared/settings'

/**
 * The git tree's typed view of its settings blob — see createTypedSettingsAccess
 * for what the factory holds and why the narrowing cast inside it is sound.
 * Named exports rather than the object itself so `use` keeps a `use*` name and
 * reads as the hook it is at every call site.
 */
const access = createTypedSettingsAccess<GitTreeSettings>('gitTree', DEFAULT_GIT_TREE_SETTINGS)

export const installGitTreeSettingsAccess = access.install
export const getGitTreeSettings = access.get
export const useGitTreeSetting = access.use
export const updateGitTreeSettings = access.update
