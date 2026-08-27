import { PANE_BUTTON } from '@shared/paneDomAttrs'
import { within } from '@testing-library/react'
import type { UserEvent } from '@testing-library/user-event'
import { headerOf } from './domQueries'

/**
 * The jsdom tier's pane-header actions — the twin of e2e/helpers/pane.ts's
 * wrappers, sharing the button ids through PANE_BUTTON while the mechanics
 * differ per tier: real geometry hides menu items behind a hover there;
 * jsdom's layout-free DOM lets a direct click land, so there is no
 * openPaneMenuItem ritual here. Before this module, the
 * within(headerOf(...)).getByTestId('pane-…-button') incantation was written
 * out ~65 times across eight files with the ids hand-spelled every time.
 */

/** Clicks any button in `pane`'s own header by test id (a type's creation button, or one of PANE_BUTTON). */
export function clickPaneButton(user: UserEvent, pane: HTMLElement, testId: string): Promise<void> {
  return user.click(within(headerOf(pane)).getByTestId(testId))
}

export const openNewTab = (user: UserEvent, pane: HTMLElement): Promise<void> =>
  clickPaneButton(user, pane, PANE_BUTTON.newTab)

export const splitHorizontal = (user: UserEvent, pane: HTMLElement): Promise<void> =>
  clickPaneButton(user, pane, PANE_BUTTON.splitHorizontal)

export const splitVertical = (user: UserEvent, pane: HTMLElement): Promise<void> =>
  clickPaneButton(user, pane, PANE_BUTTON.splitVertical)

export const openNewUnpinnedTab = (user: UserEvent, pane: HTMLElement): Promise<void> =>
  clickPaneButton(user, pane, PANE_BUTTON.newUnpinnedTab)

export const wrapInTabGroup = (user: UserEvent, pane: HTMLElement): Promise<void> =>
  clickPaneButton(user, pane, PANE_BUTTON.wrapInTabGroup)

export const clearPane = (user: UserEvent, pane: HTMLElement): Promise<void> =>
  clickPaneButton(user, pane, PANE_BUTTON.clear)

export const closePane = (user: UserEvent, pane: HTMLElement): Promise<void> =>
  clickPaneButton(user, pane, PANE_BUTTON.close)
