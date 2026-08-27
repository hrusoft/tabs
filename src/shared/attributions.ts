/**
 * Everything the About window credits: the npm packages that ship inside the
 * built app, and the two runtimes Electron brings with it.
 *
 * This is a compliance obligation, not a courtesy. Tabs itself is proprietary
 * (see LICENSE), and every dependency below is MIT or BSD — licenses whose one
 * substantive condition is that their notice travels with the binary. An
 * unattributed dependency is a license violation, which is why the list is
 * reconciled against package.json by a test rather than trusted to memory:
 * see src/shared/__tests__/attributions.test.ts, which fails by name when a
 * shipped package is missing here or an entry here no longer ships.
 *
 * No versions are recorded. A hand-kept version string is a second thing to
 * sync on every bump, and buys nothing a reader needs — while the three
 * versions that *are* worth showing (Electron, Chromium, Node) come from
 * `process.versions` at runtime and so can never be stale. See
 * `AppWindowApi.getAppInfoSync` in src/shared/api.ts.
 */

export interface Attribution {
  /** The npm package name, exactly as it appears in package.json. */
  name: string
  /** SPDX identifier, read from the package's own `license` field. */
  license: string
  /** Where a reader can go to check the claim — opened via appWindow.openExternal. */
  url: string
}

/**
 * The npm packages bundled into the shipped app, alphabetically.
 *
 * Note that several of these are *devDependencies* in package.json and still
 * ship: vite inlines React, zustand and react-resizable-panels into the
 * renderer bundles and electron-vite inlines @electron-toolkit/utils into
 * main. "Is it a dependency?" is therefore the wrong question here and the
 * reconciliation test asks a different one — see its
 * BUNDLED_DEV_DEPENDENCIES.
 *
 * `electron` is deliberately absent: it is credited by RUNTIME_COMPONENTS
 * below, which shows the running version beside it. Listing it in both places
 * printed it twice in the window, which reads as a bug rather than as
 * thoroughness — so the runtime entry names the package it covers and the
 * reconciliation counts it.
 */
export const ATTRIBUTIONS: readonly Attribution[] = [
  {
    name: '@electron-toolkit/utils',
    license: 'MIT',
    url: 'https://github.com/alex8088/electron-toolkit'
  },
  {
    name: '@xterm/addon-fit',
    license: 'MIT',
    url: 'https://github.com/xtermjs/xterm.js/tree/master/addons/addon-fit'
  },
  {
    name: '@xterm/addon-web-links',
    license: 'MIT',
    url: 'https://github.com/xtermjs/xterm.js/tree/master/addons/addon-web-links'
  },
  {
    name: '@xterm/addon-webgl',
    license: 'MIT',
    url: 'https://github.com/xtermjs/xterm.js/tree/master/addons/addon-webgl'
  },
  { name: '@xterm/xterm', license: 'MIT', url: 'https://github.com/xtermjs/xterm.js' },
  { name: 'node-pty', license: 'MIT', url: 'https://github.com/microsoft/node-pty' },
  { name: 'react', license: 'MIT', url: 'https://react.dev/' },
  { name: 'react-dom', license: 'MIT', url: 'https://react.dev/' },
  {
    name: 'react-resizable-panels',
    license: 'MIT',
    url: 'https://github.com/bvaughn/react-resizable-panels'
  },
  { name: 'zustand', license: 'MIT', url: 'https://github.com/pmndrs/zustand' }
] as const

/**
 * The two runtimes that arrive inside Electron rather than through npm, so
 * they have no package.json entry and are not reconciled — but both still owe
 * a notice, Chromium's BSD-3-Clause especially.
 *
 * `versionKey` names the `process.versions` field the About window reads, so
 * the version shown beside each is the one actually running rather than a
 * literal that could drift. See `getAppInfoSync` in src/shared/api.ts.
 *
 * `packageName` is how an entry here can *also* be the credit for an npm
 * package, so the reconciliation gate counts it as covered rather than
 * demanding a second, versionless entry in ATTRIBUTIONS. Only Electron is
 * both; Chromium and Node arrive inside it and have no package of their own.
 */
export interface RuntimeComponent extends Attribution {
  versionKey: 'electron' | 'chrome' | 'node'
  packageName?: string
}

export const RUNTIME_COMPONENTS: readonly RuntimeComponent[] = [
  {
    name: 'Electron',
    license: 'MIT',
    url: 'https://github.com/electron/electron',
    versionKey: 'electron',
    packageName: 'electron'
  },
  {
    name: 'Chromium',
    license: 'BSD-3-Clause',
    url: 'https://www.chromium.org/',
    versionKey: 'chrome'
  },
  { name: 'Node.js', license: 'MIT', url: 'https://nodejs.org/', versionKey: 'node' }
] as const
