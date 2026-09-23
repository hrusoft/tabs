import { act } from '@testing-library/react'
import { registerTestContentType } from './contentRegistryFixture'
import { secondStubContentDef, stubHeaderChromeContentDef } from './stubContent'

/**
 * The opt-in stub types, registered inside act() for the rest of the current
 * jsdom test and unregistered automatically when it ends. Their own module
 * rather than stubContent.tsx's: that one is also bundled into the Chromium
 * harness, which must not import vitest.
 */

/** A second creatable type, for the tests where "which types are offered" needs more than one answer. */
export function registerSecondStubType(): void {
  act(() => registerTestContentType(secondStubContentDef))
}

/** The stub declaring both HeaderControl and HeaderTitle. */
export function registerStubHeaderChromeType(): void {
  act(() => registerTestContentType(stubHeaderChromeContentDef))
}
