import type { LeafContent } from '@shared/model/types'
import type { ExtraStubType } from '@shared/testing/fakeApiHandle'
import App from '../App'
import type { ContentRendererDef } from '../core/registry/registry'
import { contentRegistry } from '../core/registry/registry'
import { mountRoot } from '../mountRoot'
import { registerTestContent } from './registerTestContent'
import { secondStubContentDef, stubHeaderChromeContentDef } from './stubContent'

/** Which def each opt-in name registers — see ExtraStubType for what each is for. */
const EXTRA_STUB_TYPES: Record<ExtraStubType, ContentRendererDef<LeafContent>> = {
  second: secondStubContentDef,
  'header-chrome': stubHeaderChromeContentDef
}

/** The harness's twin of main.tsx's mount: same mountRoot, stub content registry. */
export function mountTestApp(): void {
  registerTestContent()
  for (const name of window.__tabsTestExtraContent ?? []) {
    const def = EXTRA_STUB_TYPES[name]
    if (!contentRegistry.has(def.type)) contentRegistry.register(def)
  }
  mountRoot(<App />)
}
