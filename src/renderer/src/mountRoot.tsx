import { type ReactNode, StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

/**
 * The shared tail of every window entry: resolve #root and mount in
 * StrictMode. Everything order-sensitive — registrations, installTheme
 * (which must run before this so the first frame has token values) — stays
 * in the entry files, where boot order is meant to be read.
 */
export function mountRoot(children: ReactNode): void {
  const rootElement = document.getElementById('root')
  if (!rootElement) throw new Error('Missing #root element')
  createRoot(rootElement).render(<StrictMode>{children}</StrictMode>)
}
