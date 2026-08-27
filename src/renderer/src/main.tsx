import './styles/global.css'

import App from './App'
import { registerBuiltins } from './content/registerBuiltins'
import { installTheme } from './core/theme/installTheme'
import { mountRoot } from './mountRoot'

registerBuiltins()
// Before the render below, not inside an effect: global.css declares no token
// values of its own, so the first painted frame must already have them.
installTheme()

mountRoot(<App />)
