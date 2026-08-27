import type { BrowserGuestFakeHandle } from '../../../plugins/browser/shared/testing'
import type { GitTreeFakeHandle } from '../../../plugins/gitTree/shared/testing'

/**
 * The driver methods contributed by content types, one intersection member per
 * type — so a type's driver lands with the type rather than on core's shared
 * handle. The same shape `ContentControlRequest` (`../../content/externalControl.ts`)
 * uses — one member per type there too — just driver methods for tests
 * instead of wire request types.
 *
 * `emitNavKey` is the worked example: core does not subscribe to the guest
 * nav-key channel, so it is a browser concern end to end, and belongs here
 * rather than on a driver surface every content type would otherwise share.
 *
 * A type with nothing to drive contributes nothing — the terminal's fake needs
 * no handle today, so it appears here not at all rather than as an empty
 * interface.
 */
export type ContentFakeApiHandle = BrowserGuestFakeHandle & GitTreeFakeHandle
