import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { ipcMain } from 'electron'
import { IpcChannel } from '../shared/ipc'
import { PROBE_TIMEOUT_MS } from './processProbe'

const execFileAsync = promisify(execFile)

/**
 * Asks Cocoa's font registry for every installed family name, via JXA
 * (`osascript -l JavaScript`) rather than a new dependency — the same
 * mechanism used to decode a macOS Terminal.app profile during this
 * feature's feasibility check. Confirmed ~0.2s for ~180 families; the
 * no-dependency alternative (`system_profiler SPFontsDataType`) takes
 * ~14s scanning every font file's metadata on disk, which is too slow for a
 * settings dropdown.
 */
const JXA_LIST_FONT_FAMILIES = `
ObjC.import('AppKit')
const families = $.NSFontManager.sharedFontManager.availableFontFamilies
const count = families.count
const result = []
for (let i = 0; i < count; i++) result.push(ObjC.unwrap(families.objectAtIndex(i)))
JSON.stringify(result)
`

/**
 * Installed system font family names, for the terminal settings' font-family
 * dropdown (see TerminalSettingsPage.tsx). macOS only — resolves to an empty
 * array on any other platform, or if the osascript call fails for any
 * reason, and the renderer falls back to a free-text input.
 */
async function listFontFamilies(): Promise<string[]> {
  if (process.platform !== 'darwin') return []
  try {
    const { stdout } = await execFileAsync(
      'osascript',
      ['-l', 'JavaScript', '-e', JXA_LIST_FONT_FAMILIES],
      // Same rationale as processProbe.ts's PROBE_TIMEOUT_MS: an uncapped
      // hang here (e.g. a first-run Automation permission prompt) would wedge
      // the awaiting fontsListFamilies IPC handler forever instead of
      // degrading to the empty-array fallback below.
      { timeout: PROBE_TIMEOUT_MS }
    )
    const families = JSON.parse(stdout)
    return Array.isArray(families) ? families : []
  } catch {
    return []
  }
}

export function registerFontsIpc(): void {
  ipcMain.handle(IpcChannel.fontsListFamilies, () => listFontFamilies())
}
