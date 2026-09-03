import { act, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { Tooltip } from '../Tooltip'

/**
 * The component's own show/hide *timing* — wiring this tier can honestly
 * test, since it's state and effect scheduling, not appearance. Whether the
 * bubble actually renders somewhere visible, unclipped, and the right shade
 * against a real layout is a claim jsdom cannot back up at all
 * (`getBoundingClientRect` is always zero there — see Tooltip.tsx's own
 * comment on the bug that shipped because of exactly this gap) — that's
 * e2e/browser/tooltip.spec.ts's job, plus the Electron-tier hover tests in
 * browser.spec.ts and keyboard-shortcuts.spec.ts for the two callers that
 * can't render in the non-Electron tiers.
 *
 * Plain `fireEvent`, not `userEvent`: userEvent's own async pointer-event
 * machinery hangs when paired with fake timers here (the one other fake-timer
 * test, content/__tests__/reattachRegistry.test.ts, drives no DOM events at
 * all), where a raw DOM event dispatch is both simpler and exactly what's
 * needed — this is testing the effect's
 * timer, not a realistic user gesture. Advancing the fake clock is wrapped
 * in `act` because it runs the `setTimeout` that calls `setAnchor`, a state
 * update React needs to flush before the assertion reads the DOM.
 */

function mount(): void {
  render(
    <Tooltip label="Split horizontally">
      <button type="button">trigger</button>
    </Tooltip>
  )
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

test('a hover does not show the tooltip before its delay elapses', () => {
  mount()

  fireEvent.mouseEnter(screen.getByRole('button'))
  act(() => {
    vi.advanceTimersByTime(399)
  })
  expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()

  act(() => {
    vi.advanceTimersByTime(1)
  })
  expect(screen.getByRole('tooltip')).toHaveTextContent('Split horizontally')
})

test('moving off the trigger before the delay elapses cancels the show', () => {
  mount()

  fireEvent.mouseEnter(screen.getByRole('button'))
  act(() => {
    vi.advanceTimersByTime(200)
  })
  fireEvent.mouseLeave(screen.getByRole('button'))
  act(() => {
    vi.advanceTimersByTime(1000)
  })

  expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
})

test('moving off an already-shown tooltip hides it immediately', () => {
  mount()

  fireEvent.mouseEnter(screen.getByRole('button'))
  act(() => {
    vi.advanceTimersByTime(400)
  })
  expect(screen.getByRole('tooltip')).toBeInTheDocument()

  fireEvent.mouseLeave(screen.getByRole('button'))
  expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
})
