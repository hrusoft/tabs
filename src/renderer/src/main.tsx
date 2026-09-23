import './styles/global.css'

import App from './App'
import { installCaffeinate } from './caffeinate/installCaffeinate'
import { registerBuiltins } from './content/registerBuiltins'
import { installTheme } from './core/theme/installTheme'
import { installWindowChrome } from './core/windowChrome'
import { mountRoot } from './mountRoot'

registerBuiltins()
// Before the render below, not inside an effect: global.css declares no token
// values of its own, so the first painted frame must already have them.
installTheme()
installWindowChrome()
// Also before the render, not inside an effect — and for a sharper reason
// than installTheme's: this is what makes File → Caffeinate… deterministic
// rather than "usually works". main/menu.ts can forward
// caffeinate:open-dialog to a window whose page has only just started
// loading (see its own comment on the window-recreated case), and
// `installCaffeinate`'s onOpenDialog subscription has to already exist by
// the time that IPC message arrives, or it's lost with nothing to catch it —
// exactly the race e2e/caffeinate.spec.ts's own first test found once
// already, one effect-commit late. A module-scope call here runs as part of
// this script's top-level execution, which — because Vite emits the entry as
// an ES module, executed like a deferred script — is guaranteed to finish
// before the page's `load` event (Electron's `did-finish-load`) fires. A
// `useEffect` inside `<App/>` carries no such guarantee: it runs after
// React's first commit, a scheduled task with no fixed relationship to
// `load` at all — usually well before it in practice, which is exactly what
// made the old version of this bug easy to miss and hard to trust.
installCaffeinate()

mountRoot(<App />)
