import { createLeaf } from '@shared/model/factories'
import type { LeafContent } from '@shared/model/types'
import { act } from '@testing-library/react'
import { useEffect, useRef } from 'react'
import { registerPaneHandle } from '../core/registry/paneHandles'
import type { ContentRendererDef, ContentRendererProps } from '../core/registry/registry'
import { contentRegistry } from '../core/registry/registry'
import { useBellStore } from '../core/store/bellStore'

export const STUB_TYPE = 'stub'

function StubRenderer({ node }: ContentRendererProps<LeafContent>) {
  const contentRef = useRef<HTMLDivElement>(null)
  // The same content contract the terminal implements (TerminalRenderer.tsx):
  // a pane handle that takes real DOM focus and clears the pane's bell — the
  // pane the user is now looking at doesn't need its bell flagged. Registering
  // one makes the stub a representative content type for core's
  // focus-follows-active wiring, not just an inert box.
  //
  // The DOM half is what lets the Chromium tier see anything at all: focus is
  // refused on an element inside a `display: none` subtree (a backgrounded
  // tab), and that refusal is the whole substance of the tab-switch focus bug.
  // jsdom's isFocusableAreaElement checks neither `hidden` nor `display`, so
  // only a tier with a real layout engine can hold this honest.
  useEffect(
    () =>
      registerPaneHandle(node.id, {
        focus: () => {
          contentRef.current?.focus()
          useBellStore.getState().clear(node.id)
        },
        // Guarded like the terminal's: by the time a deactivation runs, focus
        // may already belong to the next pane.
        blur: () => {
          if (contentRef.current === document.activeElement) contentRef.current?.blur()
        }
      }),
    [node.id]
  )
  // tabIndex -1: programmatically focusable the way a terminal's helper
  // textarea is, without joining the page's tab order. `outline: none` with
  // it, because the UA focus ring is an artifact of the stand-in and not of
  // anything the app does — it paints a line right at the pane's content edge,
  // where the real content types paint none (xterm focuses an offscreen
  // textarea, a `<webview>` outlines nothing), and chrome-depth.spec.ts
  // measures exactly those pixels.
  return (
    <div data-testid="stub-content" tabIndex={-1} ref={contentRef} style={{ outline: 'none' }}>
      {node.id}
    </div>
  )
}

function StubIcon() {
  return <span aria-hidden="true">▣</span>
}

/**
 * Non-empty leaf content for tests that need "a pane holding something"
 * without a terminal's pty or a browser's webview behind it: real pane
 * chrome, a real creation button (so drag tests get center-merge targets and
 * derived-title tests get a displayName), zero runtime dependencies.
 */
export const stubContentDef: ContentRendererDef<LeafContent> = {
  type: STUB_TYPE,
  displayName: 'Stub',
  Component: StubRenderer,
  createAction: {
    testId: 'pane-new-stub-button',
    label: 'New stub',
    Icon: StubIcon,
    createContent: () => createLeaf(STUB_TYPE)
  }
}

export const SECOND_STUB_TYPE = 'stub-two'

/**
 * Registers the second stub type inside act() — four jsdom files need "which
 * one is the root button" to be a real question, and each was writing out the
 * same act-wrapped register plus the same afterEach. Pair with
 * `unregisterSecondStubType` in afterEach (or a finally).
 */
export function registerSecondStubType(): void {
  act(() => {
    contentRegistry.register(secondStubContentDef)
  })
}

export function unregisterSecondStubType(): void {
  contentRegistry.unregister(SECOND_STUB_TYPE)
}

function SecondStubRenderer({ node }: ContentRendererProps<LeafContent>) {
  return <div data-testid="stub-two-content">{node.id}</div>
}

function SecondStubIcon() {
  return <span aria-hidden="true">▤</span>
}

/**
 * A *second* creation-capable type, registered per test on top of the stub
 * above — enough to make "which type owns the always-visible root button, and
 * which fall into the dropdown" a real question rather than a degenerate one.
 *
 * Deliberately not registered by registerTestContent: the tests that want it
 * are about registration order and enablement, so each registers and
 * unregisters it itself. It lives here rather than inline in those tests
 * because they assert on its type id and test ids, and two copies of those
 * strings would have to be edited together.
 */
export const secondStubContentDef: ContentRendererDef<LeafContent> = {
  type: SECOND_STUB_TYPE,
  displayName: 'Stub two',
  Component: SecondStubRenderer,
  createAction: {
    testId: 'pane-new-stub-two-button',
    label: 'New stub two',
    Icon: SecondStubIcon,
    createContent: () => createLeaf(SECOND_STUB_TYPE)
  }
}
