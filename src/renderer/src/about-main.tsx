import './styles/global.css'

import { AboutWindow } from './about/AboutWindow'
import { installTheme } from './core/theme/installTheme'
import { mountRoot } from './mountRoot'

// See main.tsx: before the render, not inside an effect — global.css declares
// no token values of its own, so the first painted frame must already have
// them. This window never changes the theme, but it still has to follow the
// live one, which the store subscription inside installTheme handles.
installTheme()

mountRoot(<AboutWindow />)
