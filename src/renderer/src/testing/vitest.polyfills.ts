import { randomUUID } from 'node:crypto'

// jsdom gap-fills that must be in place before react-dom's module init runs —
// this file is the first setupFiles entry and must import nothing that pulls
// in react-dom (vitest.setup.ts's RTL import does, and import hoisting would
// run it ahead of any statement here).

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean
}

// React's act() support outside a jest environment.
globalThis.IS_REACT_ACT_ENVIRONMENT = true

// jsdom supports webkit-prefixed animation *styles* but not the
// AnimationEvent/TransitionEvent constructors — a combination that makes
// react-dom's vendor-prefix sniffing register 'webkitAnimationEnd' & co. as
// the native event names, so onAnimationEnd handlers never fire from a plain
// animationend dispatch. With the constructors present, React keeps the
// unprefixed names.
class AnimationEventStub extends Event {}
class TransitionEventStub extends Event {}
globalThis.AnimationEvent ??= AnimationEventStub as unknown as typeof AnimationEvent
globalThis.TransitionEvent ??= TransitionEventStub as unknown as typeof TransitionEvent

// jsdom has no matchMedia; installTheme reads '(prefers-color-scheme: dark)'
// and subscribes to its change event. This gap-fill only has to keep that from
// throwing — it always answers "no preference" and never fires. A test that
// needs to drive the OS preference installs its own controllable stub over
// this one (see __tests__/theme.test.tsx), which is why this stays dumb.
globalThis.matchMedia ??= ((query: string) => ({
  matches: false,
  media: query,
  onchange: null,
  addEventListener: () => {},
  removeEventListener: () => {},
  addListener: () => {},
  removeListener: () => {},
  dispatchEvent: () => false
})) as unknown as typeof matchMedia

// jsdom has no ResizeObserver; react-resizable-panels (SplitRenderer) needs one.
class ResizeObserverStub {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}
globalThis.ResizeObserver ??= ResizeObserverStub as unknown as typeof ResizeObserver

// jsdom implements no scrolling at all, so Element.prototype.scrollIntoView is
// simply absent — any component that keeps a moving selection on screen (the
// git tree's commit list) would throw rather than no-op. A stub is the honest
// gap-fill: there is no viewport here for the real thing to mean anything
// against, so "did it scroll" is not a jsdom question.
Element.prototype.scrollIntoView ??= function scrollIntoViewStub(): void {}

// ids.ts mints crypto.randomUUID() on every layout mutation; backstop jsdom's
// crypto with Node's implementation if it lacks the method.
if (typeof globalThis.crypto?.randomUUID !== 'function') {
  if (globalThis.crypto === undefined) {
    Object.defineProperty(globalThis, 'crypto', { value: {}, configurable: true })
  }
  Object.defineProperty(globalThis.crypto, 'randomUUID', {
    value: randomUUID,
    configurable: true
  })
}
