import './styles/global.css'

import { installTheme } from './core/theme/installTheme'
import { mountRoot } from './mountRoot'
import { registerBuiltinSettingsPages } from './settings/registerBuiltinPages'
import { SettingsWindow } from './settings/SettingsWindow'

registerBuiltinSettingsPages()
// See main.tsx — and note this window is where the theme is usually *changed*,
// so it has to restyle itself live, which the store subscription handles.
installTheme()

mountRoot(<SettingsWindow />)
