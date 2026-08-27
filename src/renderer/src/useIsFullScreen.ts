import { useEffect, useState } from 'react'

/**
 * The window's native (traffic-light-triggered) fullscreen state, bridged
 * from the main process. Starts `false`; the real initial value (matters
 * mainly for dev hot-reload while already fullscreen) lands once the main
 * process responds. App.tsx, the one caller, publishes it to CSS as a
 * `data-fullscreen` attribute on `.app-shell` — everything that changes in
 * fullscreen (the root bar's traffic-light gutter and extra height) is a
 * stylesheet rule keyed off that attribute, so no component below App needs
 * the value at all.
 */
export function useIsFullScreen(): boolean {
  const [isFullScreen, setIsFullScreen] = useState(false)

  useEffect(() => {
    let cancelled = false
    let sawChange = false
    window.api.appWindow.isFullScreen().then((value) => {
      // A change event that landed before this round-trip resolved is newer
      // than the answer — applying the stale initial read over it would
      // mis-show the header until the next toggle (the async-hydrate race the
      // stores avoid with sync IPC). SkillsSettings' statusSeq fends off the
      // same race between two pulls; here a boolean suffices because any push
      // beats the one initial pull.
      if (!cancelled && !sawChange) setIsFullScreen(value)
    })
    const unsubscribe = window.api.appWindow.onFullScreenChange((value) => {
      sawChange = true
      setIsFullScreen(value)
    })
    return () => {
      cancelled = true
      unsubscribe()
    }
  }, [])

  return isFullScreen
}
