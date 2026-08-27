import { useEffect, useRef, useState } from 'react'

/**
 * The inline textbox that replaces a tab or pane title until Enter, Escape,
 * or an outside click resolves it. A fresh instance mounts per edit session
 * (see the conditional render sites in TabBar/Pane), so `doneRef` needs no
 * reset — it just makes whichever of Enter/Escape/blur fires first win over
 * the redundant blur that follows a key-triggered unmount. What a saved
 * value means (rejected when empty, or clearing an override) is the
 * caller's policy, applied in `onSave`.
 */
export function InlineTitleEditor({
  initialValue,
  className,
  ariaLabel,
  onSave,
  onDone
}: {
  initialValue: string
  /** Also the testid: both call sites always passed the identical string, so the class is the identity. */
  className: string
  ariaLabel: string
  /** Receives the trimmed value when the edit resolves as a save (Enter/blur, not Escape). */
  onSave: (trimmed: string) => void
  onDone: () => void
}) {
  const [value, setValue] = useState(initialValue)
  const doneRef = useRef(false)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  const finish = (save: boolean): void => {
    if (doneRef.current) return
    doneRef.current = true
    if (save) onSave(value.trim())
    onDone()
  }

  return (
    <input
      ref={inputRef}
      className={className}
      data-testid={className}
      aria-label={ariaLabel}
      value={value}
      onChange={(event) => setValue(event.target.value)}
      onPointerDown={(event) => event.stopPropagation()}
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => {
        event.stopPropagation()
        if (event.key === 'Enter') finish(true)
        else if (event.key === 'Escape') finish(false)
      }}
      onBlur={() => finish(true)}
    />
  )
}
