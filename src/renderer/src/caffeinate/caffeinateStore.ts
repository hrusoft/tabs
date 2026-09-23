import { create } from 'zustand'

export interface CaffeinateState {
  running: boolean
  setRunning: (running: boolean) => void
}

/**
 * Whether the managed caffeinate process is running — read synchronously at
 * module init (same contract as settingsStore/layoutStore's getSync) so the
 * title-bar cup button and the File-menu-forwarded dialog gating don't flash
 * "not running" for a frame after boot, then kept live by
 * installCaffeinate.ts's subscription to `window.api.caffeinate.
 * onRunningChanged`.
 */
export const useCaffeinateStore = create<CaffeinateState>()((set) => ({
  running: window.api.caffeinate.isRunningSync(),
  setRunning: (running) => set({ running })
}))
