import App from '../App'
import { contentRegistry } from '../core/registry/registry'
import { mountRoot } from '../mountRoot'
import { registerTestContent } from './registerTestContent'
import { secondStubContentDef } from './stubContent'

/** The harness's twin of main.tsx's mount: same mountRoot, stub content registry. */
export function mountTestApp(): void {
  registerTestContent()
  // A second creation-capable type on request, so a browser-tier test can
  // measure a *row* of creation buttons rather than a lone one (the empty
  // pane's toolbar, whose whole visual specification is about how neighbours
  // meet). Opt-in rather than always on, and that is not timidity: with two
  // registered types the pane header's creation group grows a hover dropdown
  // that opens flush *over* its own root button, so the bare
  // `.click()` on `pane-new-stub-button` that a dozen existing browser specs
  // do would land on the dropdown's copy of it instead.
  if (window.__tabsTestExtraContent && !contentRegistry.has(secondStubContentDef.type)) {
    contentRegistry.register(secondStubContentDef)
  }
  mountRoot(<App />)
}
