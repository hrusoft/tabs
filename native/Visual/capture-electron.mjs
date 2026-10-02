#!/usr/bin/env node
// Renders every scenario in native/Visual/scenarios/ with the Electron app's
// real renderer (the Playwright browser-tier harness: src/renderer/harness.html
// served by vite, against the fake bridge) and writes, per scenario:
//
//   native/build/visual/electron/<name>.png            full viewport, 2x
//   native/build/visual/electron/<name>.geometry.json  element rects, CSS px
//
// The native app writes the same two files for the same scenarios; compare.py
// diffs them. The geometry format is documented in README.md — change the
// two together.
//
// Usage: node native/Visual/capture-electron.mjs [--out DIR] [--headed] [names…]

import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createServer as createNetServer } from 'node:net'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '../..')
const SCENARIOS_DIR = join(HERE, 'scenarios')
const DEVICE_SCALE_FACTOR = 2
/** Longer than every CSS transition a scenario can trigger (dropdown fade 0.1s, dock preview 0.1s, dim filter 0.15s). */
const SETTLE_MS = 400
const DRAG_STEPS = 10
/**
 * A scenario's `signals` kinds, each with the class its pane gets while the
 * cue shows and the setting that turns that cue off (Pane.tsx).
 */
const SIGNALS = {
  bell: { paneClass: 'pane-alert', setting: 'enableBellIndicator' },
  controlled: { paneClass: 'pane-controlled', setting: 'enableControlIndicator' }
}

function parseArgs(argv) {
  const options = { out: join(REPO_ROOT, 'native/build/visual/electron'), headed: false, names: [] }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--out') options.out = resolve(argv[++i])
    else if (arg === '--headed') options.headed = true
    else if (arg === '-h' || arg === '--help') {
      console.log('usage: capture-electron.mjs [--out DIR] [--headed] [scenario names…]')
      process.exit(0)
    } else options.names.push(arg.replace(/\.json$/, ''))
  }
  return options
}

function loadScenarios(names) {
  const all = readdirSync(SCENARIOS_DIR)
    .filter((file) => file.endsWith('.json'))
    .map((file) => basename(file, '.json'))
    .sort()
  const unknown = names.filter((name) => !all.includes(name))
  if (unknown.length) throw new Error(`unknown scenario(s): ${unknown.join(', ')}`)
  return (names.length ? names : all).map((name) => {
    const scenario = JSON.parse(readFileSync(join(SCENARIOS_DIR, `${name}.json`), 'utf8'))
    if (!scenario.size?.width || !scenario.size?.height) throw new Error(`${name}: missing size`)
    if (scenario.layout?.root?.type !== 'tabs')
      throw new Error(`${name}: layout.root must be a tabs group`)
    for (const [id, kinds] of Object.entries(scenario.signals ?? {})) {
      const bad = Array.isArray(kinds)
        ? kinds.filter((kind) => !Object.hasOwn(SIGNALS, kind))
        : [kinds]
      if (bad.length) throw new Error(`${name}: signals.${id}: unknown kind(s) ${bad.join(', ')}`)
    }
    if (scenario.pulse !== undefined && !(Number.isFinite(scenario.pulse) && scenario.pulse >= 0)) {
      throw new Error(`${name}: pulse must be a number of seconds >= 0`)
    }
    if (scenario.gitTree !== undefined) validateGitTree(name, scenario)
    validateBrowser(name, scenario)
    validatePalette(name, scenario)
    return { name, ...scenario }
  })
}

/** The layout node with this id, wherever it sits in the snapshot (docked or floating). */
function findLayoutNode(value, id) {
  if (value === null || typeof value !== 'object') return null
  if (!Array.isArray(value) && value.id === id && typeof value.type === 'string') return value
  for (const child of Object.values(value)) {
    const found = findLayoutNode(child, id)
    if (found) return found
  }
  return null
}

/**
 * A scenario's `gitTree`: exactly one leaf (the fake bridge is global), of
 * type gitTree in the layout, seeded with exactly one of `log`/`failure`.
 */
function validateGitTree(name, scenario) {
  const entries = Object.entries(scenario.gitTree ?? {})
  if (entries.length !== 1) throw new Error(`${name}: gitTree must seed exactly one leaf`)
  const [[id, spec]] = entries
  if (findLayoutNode(scenario.layout, id)?.type !== 'gitTree') {
    throw new Error(`${name}: gitTree.${id}: no gitTree leaf with that id in the layout`)
  }
  if ((spec.log === undefined) === (spec.failure === undefined)) {
    throw new Error(`${name}: gitTree.${id}: exactly one of log and failure`)
  }
  if (spec.select !== undefined && spec.failure) {
    throw new Error(`${name}: gitTree.${id}: select needs a log`)
  }
  if (spec.log && typeof spec.select === 'string' && spec.select !== '') {
    if (!spec.log.commits.some((commit) => commit.hash === spec.select)) {
      throw new Error(`${name}: gitTree.${id}: select ${spec.select} is not in the log`)
    }
  }
  if (spec.select === '' && !spec.log?.hasUncommittedChanges) {
    throw new Error(`${name}: gitTree.${id}: select "" needs hasUncommittedChanges`)
  }
}

/** Every layout node of this type, wherever it sits in the snapshot (docked or floating). */
function findLayoutNodes(value, type, found = []) {
  if (value === null || typeof value !== 'object') return found
  if (!Array.isArray(value) && value.type === type && typeof value.id === 'string')
    found.push(value)
  for (const child of Object.values(value)) findLayoutNodes(child, type, found)
  return found
}

/**
 * A scenario's `browser`: one block per `browser` leaf in the layout, each with
 * a `page` color; `canGoBack`/`canGoForward`/`focusAddress` are booleans.
 */
function validateBrowser(name, scenario) {
  const leaves = findLayoutNodes(scenario.layout, 'browser').map((leaf) => leaf.id)
  const seeded = Object.keys(scenario.browser ?? {})
  for (const type of scenario.creationActions ?? []) {
    if (type !== 'browser') throw new Error(`${name}: creationActions: unknown type ${type}`)
  }
  if (leaves.length === 0 && scenario.browser === undefined) return
  for (const id of leaves) {
    if (!seeded.includes(id)) throw new Error(`${name}: browser leaf ${id} has no browser block`)
  }
  for (const [id, spec] of Object.entries(scenario.browser ?? {})) {
    if (!leaves.includes(id))
      throw new Error(`${name}: browser.${id}: no browser leaf with that id`)
    if (typeof spec.page !== 'string')
      throw new Error(`${name}: browser.${id}: page must be a CSS color`)
    for (const key of ['canGoBack', 'canGoForward', 'focusAddress']) {
      if (spec[key] !== undefined && typeof spec[key] !== 'boolean')
        throw new Error(`${name}: browser.${id}: ${key} must be a boolean`)
    }
    const unknown = Object.keys(spec).filter(
      (key) => !['page', 'canGoBack', 'canGoForward', 'focusAddress'].includes(key)
    )
    if (unknown.length)
      throw new Error(`${name}: browser.${id}: unknown key(s) ${unknown.join(', ')}`)
  }
}

/**
 * A scenario's `palette`: `{step: "type" | "placement", highlight?, hover?}`
 * (the ⌘P palette opened the way the app does, then driven by real keys and
 * mouse), and `paletteTypes`: how many extra stub types the list holds.
 */
function validatePalette(name, scenario) {
  const { palette, paletteTypes } = scenario
  if (paletteTypes !== undefined && !(Number.isInteger(paletteTypes) && paletteTypes >= 0))
    throw new Error(`${name}: paletteTypes must be an integer >= 0`)
  if (palette === undefined) return
  if (!['type', 'placement'].includes(palette.step))
    throw new Error(`${name}: palette.step must be "type" or "placement"`)
  for (const key of ['highlight', 'hover']) {
    if (palette[key] !== undefined && !(Number.isInteger(palette[key]) && palette[key] >= 0))
      throw new Error(`${name}: palette.${key} must be an integer >= 0`)
  }
  const unknown = Object.keys(palette).filter(
    (key) => !['step', 'highlight', 'hover'].includes(key)
  )
  if (unknown.length) throw new Error(`${name}: palette: unknown key(s) ${unknown.join(', ')}`)
}

function freePort() {
  return new Promise((resolvePort, reject) => {
    const server = createNetServer()
    server.unref()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolvePort(port))
    })
  })
}

/**
 * Runs in the page. Everything a native renderer must reproduce, keyed by the
 * layout model's ids so the two sides line up without any DOM knowledge.
 * Only rendered elements are reported (a background tab's subtree is
 * display:none and simply absent). See README.md for the exact format.
 */
function collectGeometry(paletteStepKind) {
  const round = (value) => Math.round(value * 100) / 100
  const toRect = (r) => [round(r.x), round(r.y), round(r.width), round(r.height)]
  const rendered = (el) => el !== null && el !== undefined && el.getClientRects().length > 0
  const rectOf = (el) => (rendered(el) ? toRect(el.getBoundingClientRect()) : null)
  const intersect = (a, b) => {
    const left = Math.max(a.left, b.left)
    const top = Math.max(a.top, b.top)
    const right = Math.min(a.right, b.right)
    const bottom = Math.min(a.bottom, b.bottom)
    return { x: left, y: top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) }
  }
  /** The laid-out text itself (a Range over the element's contents), clipped to the element's own box — what is visible when the text is truncated with an ellipsis. */
  const textRectOf = (el) => {
    if (!rendered(el) || !el.textContent) return null
    const range = document.createRange()
    range.selectNodeContents(el)
    return toRect(intersect(range.getBoundingClientRect(), el.getBoundingClientRect()))
  }
  /** The y of the element's first-line text baseline, via a zero-size inline-block probe (whose bottom edge sits on the baseline). */
  const baselineOf = (el) => {
    if (!rendered(el) || !el.textContent) return null
    const probe = document.createElement('span')
    probe.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline'
    el.appendChild(probe)
    const y = probe.getBoundingClientRect().bottom
    probe.remove()
    return round(y)
  }
  const visible = (el) => {
    if (!rendered(el)) return false
    for (let node = el; node; node = node.parentElement) {
      const style = getComputedStyle(node)
      if (style.visibility === 'hidden' || Number(style.opacity) < 0.5) return false
    }
    return true
  }
  // Keyed by data-testid. Every chrome button is wrapped in a
  // `display: contents` .tooltip-trigger span, so no `>` selectors across it.
  const buttonsIn = (buttons) => {
    const out = {}
    for (const button of buttons) {
      const rect = rectOf(button)
      if (rect && button.dataset.testid) out[button.dataset.testid] = rect
    }
    return out
  }
  // The cue icons (CueIcon.tsx) that are direct children of a pane header or
  // a tab, keyed by signal kind. Added to the geometry only when non-empty,
  // so a scenario without signals dumps exactly what it did before they existed.
  const SIGNAL_ICONS = { 'bell-icon': 'bell', 'control-icon': 'controlled' }
  const signalIconsIn = (parent) => {
    const out = {}
    if (!parent) return out
    for (const [className, kind] of Object.entries(SIGNAL_ICONS)) {
      const rect = rectOf(parent.querySelector(`:scope > .${className}`))
      if (rect) out[kind] = rect
    }
    return out
  }
  const withSignalIcons = (entry, parent) => {
    const icons = signalIconsIn(parent)
    return Object.keys(icons).length ? { ...entry, signalIcons: icons } : entry
  }

  const panes = {}
  for (const el of document.querySelectorAll('.pane[data-dock-id]')) {
    const rect = rectOf(el)
    if (!rect) continue
    const header = el.querySelector(':scope > .pane-header')
    const title = header?.querySelector('.pane-title') ?? null
    // Which cue colors the content outline: the Controlled panes rule comes
    // after the Bell one in global.css, so it wins for a pane with both.
    const cue = el.classList.contains('pane-controlled')
      ? 'controlled'
      : el.classList.contains('pane-alert')
        ? 'bell'
        : null
    const entry = {
      rect,
      body: rectOf(el.querySelector(':scope > .pane-body')),
      header: rectOf(header),
      title: textRectOf(title),
      titleBaseline: baselineOf(title),
      titleText: title?.textContent ?? null,
      grip: rectOf(header?.querySelector(':scope > .pane-grip')),
      depth: Number(el.style.getPropertyValue('--depth') || 0),
      active: el.classList.contains('pane-active'),
      // Visually dimmed: the class is on every inactive pane, but the filter
      // only ever reaches non-group content (`:not(.tabs-view)` in global.css).
      dimmed:
        el.classList.contains('pane-dimmed') &&
        el.querySelector(':scope > .pane-body > .tabs-view') === null,
      dragging: el.classList.contains('pane-dragging')
    }
    panes[el.dataset.dockId] = withSignalIcons(cue ? { ...entry, cue } : entry, header)
  }

  const tabBars = {}
  for (const bar of document.querySelectorAll('.tab-bar[data-drop-group-id]')) {
    const rect = rectOf(bar)
    if (!rect) continue
    const tabs = {}
    for (const tab of bar.querySelectorAll('.tab[data-drop-tab-id]')) {
      const title = tab.querySelector('.tab-title')
      const entry = {
        rect: rectOf(tab),
        title: textRectOf(title),
        titleBox: rectOf(title),
        baseline: baselineOf(title),
        text: title?.textContent ?? '',
        truncated: title ? title.scrollWidth > title.clientWidth : false,
        close: rectOf(tab.querySelector('.tab-close')),
        active: tab.classList.contains('tab-active'),
        dragging: tab.classList.contains('tab-dragging')
      }
      tabs[tab.dataset.dropTabId] = withSignalIcons(entry, tab)
    }
    tabBars[bar.dataset.dropGroupId] = {
      rect,
      root: bar.classList.contains('tab-bar-root'),
      strip: rectOf(bar.querySelector(':scope > .tab-strip')),
      grip: rectOf(bar.querySelector(':scope > .pane-grip')),
      newTab: rectOf(bar.querySelector('.tab-strip-new-tab-button')),
      settings: rectOf(bar.querySelector('[data-testid="settings-open-button"]')),
      tabs
    }
    // Only while caffeinate runs (key omitted otherwise, so older goldens hold).
    const cup = bar.querySelector('[data-testid="caffeinate-decaf-button"]')
    if (cup) tabBars[bar.dataset.dropGroupId].caffeinate = rectOf(cup)
  }

  // Keyed by the id of the pane whose chrome (leaf header or tab bar) holds them.
  const controls = {}
  for (const el of document.querySelectorAll('.pane-header-controls')) {
    const rect = rectOf(el)
    const owner = el.closest('[data-pane-drag-id]')
    if (!rect || !owner) continue
    let dropdown = null
    for (const menu of el.querySelectorAll('.pane-header-dropdown')) {
      if (!visible(menu)) continue
      dropdown = {
        rect: rectOf(menu),
        items: buttonsIn(menu.querySelectorAll('.pane-header-button'))
      }
    }
    controls[owner.dataset.paneDragId] = {
      rect,
      visible: visible(el),
      buttons: buttonsIn(
        [...el.querySelectorAll('.pane-header-button')].filter(
          (button) => !button.closest('.pane-header-dropdown')
        )
      ),
      separator: rectOf(el.querySelector('.pane-header-separator')),
      dropdown
    }
  }

  const separators = {}
  for (const el of document.querySelectorAll('.split-separator[data-split-id]')) {
    const rect = rectOf(el)
    if (rect) separators[`${el.dataset.splitId}:${el.dataset.separatorIndex}`] = rect
  }

  const floating = {}
  for (const el of document.querySelectorAll('.floating-window[data-floating-id]')) {
    const rect = rectOf(el)
    if (rect) floating[el.dataset.floatingId] = rect
  }

  const emptyToolbars = {}
  for (const el of document.querySelectorAll('.empty-pane[data-drop-empty-pane-id]')) {
    const toolbar = el.querySelector('.empty-pane-toolbar')
    const rect = rectOf(toolbar)
    if (!rect) continue
    emptyToolbars[el.dataset.dropEmptyPaneId] = {
      rect,
      buttons: [...toolbar.querySelectorAll('button')].map(rectOf)
    }
  }

  // Git trees (the real pane: the toolbar is the header's title, the body is
  // .git-tree-container; see packages/plugin-gitTree/testing/visualCapture.ts). Added to the
  // geometry only when the scenario has one, so every other dump is unchanged.
  const textNodeRectOf = (node, clip) => {
    if (!node?.textContent || !rendered(clip)) return null
    const range = document.createRange()
    range.selectNodeContents(node)
    return toRect(intersect(range.getBoundingClientRect(), clip.getBoundingClientRect()))
  }
  // A form control's text can't hold a probe, so its baseline is measured on
  // a hidden stand-in laid over it: the same border box, padding, border
  // widths and font, with its one line centered vertically in the content
  // box — which is how Chromium places a text field's inner editor and a
  // menulist's label (verified against the pixels; see README).
  const controlTextOf = (el, text) => {
    if (!rendered(el)) return null
    const style = getComputedStyle(el)
    const box = el.getBoundingClientRect()
    const mirror = document.createElement('div')
    mirror.style.cssText = [
      'position:fixed',
      `left:${box.left}px`,
      `top:${box.top}px`,
      `width:${box.width}px`,
      `height:${box.height}px`,
      'box-sizing:border-box',
      'display:flex',
      'align-items:center',
      'visibility:hidden',
      'white-space:pre',
      `padding:${style.padding}`,
      `border-style:solid`,
      `border-color:transparent`,
      `border-width:${style.borderWidth}`,
      `font:${style.font}`,
      `line-height:${style.lineHeight}`
    ].join(';')
    const line = document.createElement('span')
    line.textContent = text || ' '
    mirror.appendChild(line)
    document.body.appendChild(mirror)
    const baseline = baselineOf(line)
    const rect = toRect(line.getBoundingClientRect())
    mirror.remove()
    return { rect, baseline }
  }
  const controlBaselineOf = (el, text) => controlTextOf(el, text)?.baseline ?? null
  const gitTree = {}
  for (const el of document.querySelectorAll('.git-tree-container')) {
    const pane = el.closest('.pane[data-dock-id]')
    const id = pane?.dataset.dockId
    if (!id || !rendered(el)) continue
    const header = pane.querySelector(':scope > .pane-header')
    const pathInput = header?.querySelector('.git-tree-path-input') ?? null
    const browse = header?.querySelector('[data-testid="git-tree-browse-button"]') ?? null
    const head = header?.querySelector('.git-tree-head') ?? null
    const select = header?.querySelector('.git-tree-branch-select') ?? null
    const container = el
    const list = container?.querySelector('.git-tree-list') ?? null
    const notice = container?.querySelector(':scope > .git-tree-notice') ?? null
    const detail = container?.querySelector('.git-tree-detail') ?? null
    const divider = container?.querySelector('.git-tree-divider') ?? null

    const rows = {}
    for (const row of list?.querySelectorAll('.git-tree-row') ?? []) {
      const subject = row.querySelector('.git-tree-subject')
      const hash = row.querySelector('.git-tree-hash')
      // The subject's own text: the text node after the ref pills.
      const subjectNode = [...subject.childNodes].find((node) => node.nodeType === Node.TEXT_NODE)
      rows[row.dataset.hash === '' ? 'working-tree' : row.dataset.hash] = {
        rect: rectOf(row),
        gutter: rectOf(row.querySelector(':scope > .git-graph')),
        hash: textRectOf(hash),
        hashBaseline: baselineOf(hash),
        subject: rectOf(subject),
        subjectText: textNodeRectOf(subjectNode, subject),
        subjectBaseline: baselineOf(subject),
        truncated: subject.scrollWidth > subject.clientWidth,
        refs: [...subject.querySelectorAll('.git-tree-ref')].map(rectOf),
        author: textRectOf(row.querySelector('.git-tree-author')),
        date: textRectOf(row.querySelector('.git-tree-date')),
        selected: row.getAttribute('aria-selected') === 'true',
        phantom: row.classList.contains('git-tree-row-phantom')
      }
    }

    const fields = []
    for (const dt of detail?.querySelectorAll('.git-tree-fields > dt') ?? []) {
      fields.push({ dt: textRectOf(dt), dd: textRectOf(dt.nextElementSibling) })
    }
    const files = []
    for (const file of detail?.querySelectorAll('.git-tree-file') ?? []) {
      const stat = file.querySelector('.git-tree-file-stat')
      files.push({
        row: rectOf(file),
        stat: rectOf(stat),
        insertions: textRectOf(stat.querySelector('.git-tree-insertions')),
        deletions: textRectOf(stat.querySelector('.git-tree-deletions')),
        binary: textRectOf(stat.querySelector('.git-tree-binary')),
        path: textRectOf(file.querySelector('.git-tree-file-path'))
      })
    }

    gitTree[id] = {
      container: rectOf(el),
      pathInput: rectOf(pathInput),
      browse: rectOf(browse),
      pathBaseline: controlBaselineOf(pathInput, pathInput?.value),
      head: rectOf(head),
      headText: textRectOf(head),
      headBaseline: baselineOf(head),
      select: rectOf(select),
      selectBaseline: controlBaselineOf(select, select?.selectedOptions[0]?.textContent),
      state: list ? 'list' : notice?.dataset.testid === 'git-tree-loading' ? 'loading' : 'notice',
      notice: rectOf(notice),
      noticeLines: [...(notice?.querySelectorAll(':scope > p') ?? [])].map((p) => ({
        text: textRectOf(p),
        baseline: baselineOf(p)
      })),
      list: rectOf(list),
      rows,
      loadMore: rectOf(list?.querySelector('.git-tree-load-more')),
      divider: rectOf(divider),
      dividerCollapsed: divider?.classList.contains('git-tree-divider-collapsed') ?? false,
      detail: rectOf(detail),
      message: rectOf(detail?.querySelector('.git-tree-message')),
      fields,
      files,
      detailNotes: [...(detail?.querySelectorAll('.git-tree-dim') ?? [])].map(textRectOf)
    }
  }

  // Browsers (the real header chrome around a stand-in page; see
  // packages/plugin-browser/testing/visualCapture.ts). Keyed by pane id, added
  // only when the scenario has one, so every other dump is unchanged.
  const browser = {}
  for (const page of document.querySelectorAll('.pane-body .browser-content > .browser-webview')) {
    const pane = page.closest('.pane[data-dock-id]')
    const id = pane?.dataset.dockId
    if (!id || !rendered(page)) continue
    const header = pane.querySelector(':scope > .pane-header')
    const button = (testId) => header?.querySelector(`[data-testid="${testId}"]`) ?? null
    const bar = header?.querySelector('.browser-address-bar') ?? null
    const segment = bar?.querySelector('.browser-title-segment') ?? null
    const input = bar?.querySelector('.browser-address-input') ?? null
    const address = input && controlTextOf(input, input.value)
    // The typed text's line box, clipped to the input's content box (a long URL runs past it).
    if (address) {
      const box = input.getBoundingClientRect()
      const style = getComputedStyle(input)
      const [x, y, w, h] = address.rect
      const left = Math.max(x, box.left + Number.parseFloat(style.paddingLeft))
      const right = Math.min(x + w, box.right - Number.parseFloat(style.paddingRight))
      address.rect = [round(left), y, round(Math.max(0, right - left)), h]
    }
    browser[id] = {
      page: rectOf(page),
      back: rectOf(button('browser-back-button')),
      forward: rectOf(button('browser-forward-button')),
      refresh: rectOf(button('browser-refresh-button')),
      backDisabled: button('browser-back-button')?.disabled ?? null,
      forwardDisabled: button('browser-forward-button')?.disabled ?? null,
      addressBar: rectOf(bar),
      titleSegment: rectOf(segment),
      titleText: textRectOf(segment),
      titleBaseline: baselineOf(segment),
      titleString: segment?.textContent ?? null,
      titleTruncated: segment ? segment.scrollWidth > segment.clientWidth : false,
      addressInput: rectOf(input),
      addressText: address?.rect ?? null,
      addressBaseline: address?.baseline ?? null,
      addressValue: input?.value ?? null,
      focused: input !== null && document.activeElement === input
    }
  }

  // The command palette (CommandPalette.tsx), only while one is open, so every
  // other dump is unchanged. A badge is an inline-flex box, where a probe
  // would become a centered flex item of its own: its baseline is taken with
  // the text wrapped in a span (a flex item holding a line box) and the probe
  // inside that, then restored.
  const badgeBaselineOf = (badge) => {
    if (!rendered(badge) || !badge.textContent) return null
    const text = badge.textContent
    const wrapper = document.createElement('span')
    wrapper.textContent = text
    badge.replaceChildren(wrapper)
    const y = baselineOf(wrapper)
    badge.replaceChildren(text)
    return y
  }
  let palette = null
  const backdrop = document.querySelector('.command-palette-backdrop')
  if (rendered(backdrop)) {
    const rows = [...backdrop.querySelectorAll('.command-palette-item')].map((row) => {
      const badge = row.querySelector('.command-palette-badge')
      const label = row.querySelector('.command-palette-label')
      const icon = [...row.children].find((child) => child !== badge && child !== label) ?? null
      return {
        rect: rectOf(row),
        highlighted: row.classList.contains('command-palette-item-highlighted'),
        badge: rectOf(badge),
        badgeText: textRectOf(badge),
        badgeBaseline: badgeBaselineOf(badge),
        icon: rectOf(icon),
        label: textRectOf(label),
        labelBaseline: baselineOf(label),
        text: label?.textContent ?? ''
      }
    })
    const empty = backdrop.querySelector('.command-palette-empty')
    palette = {
      step: empty ? 'empty' : paletteStepKind,
      backdrop: rectOf(backdrop),
      panel: rectOf(backdrop.querySelector('.command-palette')),
      rows,
      empty: empty
        ? { text: textRectOf(empty), baseline: baselineOf(empty), string: empty.textContent }
        : null
    }
  }

  const dropTarget = document.querySelector('.empty-pane-drop-target[data-drop-empty-pane-id]')
  const ghost = document.querySelector('.drag-ghost')
  const tooltip = document.querySelector('.tooltip-bubble')
  return {
    size: { width: window.innerWidth, height: window.innerHeight },
    panes,
    tabBars,
    controls,
    separators,
    floating,
    emptyToolbars,
    dockPreview: rectOf(document.querySelector('.dock-preview')),
    dockPreviewPane:
      document.querySelector('.dock-preview')?.closest('[data-dock-id]')?.dataset.dockId ?? null,
    emptyDropTarget: dropTarget?.dataset.dropEmptyPaneId ?? null,
    dragGhost: rectOf(ghost),
    dragGhostText: ghost?.textContent ?? null,
    dropIndicator: rectOf(document.querySelector('.tab-drop-indicator')),
    tooltip: rendered(tooltip) ? { rect: rectOf(tooltip), text: tooltip.textContent } : null,
    contextMenu: rectOf(document.querySelector('.context-menu')),
    ...(Object.keys(gitTree).length ? { gitTree } : {}),
    ...(Object.keys(browser).length ? { browser } : {}),
    ...(palette ? { palette } : {})
  }
}

/** Pretty JSON with every all-number array (a rect) kept on one line. */
function formatJson(value) {
  return `${JSON.stringify(value, null, 2).replace(/\[\s+(-?[\d.e+-]+(?:,\s+-?[\d.e+-]+)*)\s+\]/g, (_, body) => `[${body.split(/,\s+/).join(', ')}]`)}\n`
}

/**
 * Tooltips are app-drawn bubbles that appear 400ms after hover (Tooltip.tsx),
 * which a fixed settle delay would race. Hidden unless a scenario opts in with
 * `"tooltip": true`, in which case the capture waits for the bubble instead.
 */
const HIDE_TOOLTIPS_CSS = '.tooltip-bubble { display: none !important; }'

/**
 * Runs in the page: raises a scenario's `signals` through the app's own
 * stores. A bell rings the real bellStore — imported by its vite URL, which is
 * the same module instance the app renders from (vite's root is src/renderer
 * and serves each source file at one URL) — with `document.hasFocus` stubbed
 * false for the ring, so a bell on the active pane is kept as when the window
 * is unfocused (ring() drops it otherwise). Controlled goes through the fake
 * bridge's ownership push, the path main's ledger takes.
 */
async function seedSignals(signals) {
  const { useBellStore } = await import('/src/core/store/bellStore.ts')
  document.hasFocus = () => false
  try {
    for (const [id, kinds] of Object.entries(signals)) {
      for (const kind of kinds) {
        if (kind === 'bell') useBellStore.getState().ring(id)
        else if (kind === 'controlled') window.__fakeApi.emitOwnershipChanged(id, true)
      }
    }
  } finally {
    // The stub is an own property shadowing Document.prototype.hasFocus.
    delete document.hasFocus
  }
}

/**
 * Runs in the page: what doesn't match the seeded `signals` — every seeded
 * pane must carry its cue's class, or must not when the scenario's settings
 * turn that indicator off.
 */
function signalMismatches({ signals, settings, kinds }) {
  const problems = []
  for (const [id, raised] of Object.entries(signals)) {
    const pane = document.querySelector(`.pane[data-dock-id="${CSS.escape(id)}"]`)
    if (!pane) {
      problems.push(`${id}: no such pane`)
      continue
    }
    for (const kind of raised) {
      const { paneClass, setting } = kinds[kind]
      const expected = settings[setting] !== false
      if (pane.classList.contains(paneClass) !== expected) {
        const what = expected ? 'missing' : 'shown though turned off'
        problems.push(`${id}: ${kind} cue ${what} (.${paneClass})`)
      }
    }
  }
  return problems
}

/**
 * Runs in the page: pauses every CSS animation (the cue pulses; they include
 * `::after` pseudo-element animations) at `ms` into its cycle. Transitions are
 * left alone: rewinding one would undo a settled hover or dim. Returns what it
 * froze.
 */
function freezeAnimations(ms) {
  const frozen = []
  for (const animation of document.getAnimations()) {
    if (!(animation instanceof CSSAnimation)) continue
    animation.pause()
    animation.currentTime = ms
    frozen.push(`${animation.animationName}${animation.effect?.pseudoElement ?? ''}`)
  }
  return frozen
}

/**
 * Runs in the page: what about a git tree doesn't (yet) match its seed. With
 * `rowsOnly`, just whether the list has all its rows (before `select` clicks
 * one); otherwise everything the capture relies on: the header's path bar, the
 * HEAD label, which row is selected, and — unless the
 * details are collapsed — that row's detail, whose read is debounced 100ms.
 */
function gitTreeProblems({ id, spec, collapsed, rowsOnly }) {
  const pane = document.querySelector(`.pane[data-dock-id="${CSS.escape(id)}"]`)
  const capture = pane?.querySelector('[data-testid="git-tree"]')
  if (!capture) return [`${id}: no git tree rendered`]
  const problems = []
  const header = pane.querySelector(':scope > .pane-header')
  if (!header?.querySelector('.git-tree-path-input')) problems.push('no path bar in the header')
  if (spec.failure) {
    if (!capture.querySelector('[data-testid="git-tree-empty"]')) problems.push('no failure notice')
    return problems
  }
  const { log } = spec
  const rows = [...capture.querySelectorAll('.git-tree-row')]
  const expectedRows = log.commits.length + (log.hasUncommittedChanges ? 1 : 0)
  if (rows.length !== expectedRows) problems.push(`${rows.length} rows, expected ${expectedRows}`)
  if (rowsOnly) return problems
  const headName = spec.head
    ? (spec.head.name ?? `detached at ${spec.head.hash.slice(0, 7)}`)
    : 'main'
  const head = header.querySelector('.git-tree-head')?.textContent
  if (head !== headName) problems.push(`HEAD label ${head}, expected ${headName}`)
  const selected = spec.select ?? log.commits[0]?.hash
  const selectedRows = rows.filter((row) => row.getAttribute('aria-selected') === 'true')
  if (selectedRows.length !== 1 || selectedRows[0].dataset.hash !== selected) {
    problems.push(`selected ${selectedRows.map((row) => row.dataset.hash)}, expected ${selected}`)
  }
  if (!collapsed) {
    const commit = log.commits.find((candidate) => candidate.hash === selected)
    const message =
      selected === ''
        ? (spec.workingTree?.message ?? 'Uncommitted changes')
        : (spec.details?.[selected]?.message ?? commit?.subject)
    const shown = capture.querySelector('[data-testid="git-tree-message"]')?.textContent
    if (shown !== message)
      problems.push(`detail message ${JSON.stringify(shown)}, expected ${JSON.stringify(message)}`)
    const detail = selected === '' ? spec.workingTree : spec.details?.[selected]
    const files = capture.querySelectorAll('.git-tree-file').length
    if (detail && files !== detail.files.length)
      problems.push(`${files} files, expected ${detail.files.length}`)
  } else if (capture.querySelector('.git-tree-detail')) {
    problems.push('detail shown though collapsed')
  }
  return problems
}

/**
 * Runs in the page: what about a browser pane doesn't (yet) match its seed —
 * the stand-in mounted and published its instance (the header reads history
 * flags, so a Back button in its initial disabled state proves nothing until
 * the instance arrived: the flags are checked against the seed), the address
 * bar shows the layout's URL, and the address input has focus exactly when
 * `focusAddress` asks.
 */
function browserProblems({ seeds, urls, titles }) {
  const problems = []
  for (const [id, spec] of Object.entries(seeds)) {
    const pane = document.querySelector(`.pane[data-dock-id="${CSS.escape(id)}"]`)
    const header = pane?.querySelector(':scope > .pane-header')
    if (!pane?.querySelector('.browser-content > .browser-webview')) {
      problems.push(`${id}: no stand-in page rendered`)
      continue
    }
    const back = header?.querySelector('[data-testid="browser-back-button"]')
    const forward = header?.querySelector('[data-testid="browser-forward-button"]')
    const input = header?.querySelector('.browser-address-input')
    if (!back || !forward || !input) {
      problems.push(`${id}: no browser chrome in the header`)
      continue
    }
    if (back.disabled !== !spec.canGoBack) problems.push(`${id}: Back disabled=${back.disabled}`)
    if (forward.disabled !== !spec.canGoForward)
      problems.push(`${id}: Forward disabled=${forward.disabled}`)
    if (input.value !== urls[id])
      problems.push(`${id}: address ${input.value}, expected ${urls[id]}`)
    const shown = header.querySelector('.browser-title-segment')?.textContent ?? null
    if (shown !== (titles[id] || null))
      problems.push(`${id}: title ${shown}, expected ${titles[id]}`)
    const focused = document.activeElement === input
    if (focused !== (spec.focusAddress === true)) problems.push(`${id}: address focused=${focused}`)
  }
  return problems
}

/** Polls `browserProblems` until it has none; throws with the last ones after `timeout` ms. */
async function waitForBrowser(page, args, timeout = 5_000) {
  const deadline = Date.now() + timeout
  for (;;) {
    const problems = await page.evaluate(browserProblems, args)
    if (!problems.length) return
    if (Date.now() > deadline)
      throw new Error(`browser not rendered as seeded: ${problems.join('; ')}`)
    await page.waitForTimeout(50)
  }
}

/** Polls `gitTreeProblems` until it has none; throws with the last ones after `timeout` ms. */
async function waitForGitTree(page, args, timeout = 5_000) {
  const deadline = Date.now() + timeout
  for (;;) {
    const problems = await page.evaluate(gitTreeProblems, args)
    if (!problems.length) return
    if (Date.now() > deadline)
      throw new Error(`git tree not rendered as seeded: ${problems.join('; ')}`)
    await page.waitForTimeout(50)
  }
}

/**
 * Opens the palette the way the app does (the `command-palette` shortcut over
 * the fake bridge), then drives it with real input: Enter on the first row for
 * the placement step, ArrowDown presses to `highlight`, and a mouse move to
 * the centre of row `hover`, which wins the highlight (onMouseEnter). Throws
 * unless the step, the row count and the highlighted row are what was asked.
 */
async function drivePalette(page, spec) {
  await page.evaluate(() => window.__fakeApi.fireShortcut('command-palette'))
  await page.waitForSelector('.command-palette-backdrop', { timeout: 5_000 })
  const backdropFocused = () =>
    page.evaluate(() => document.activeElement?.classList.contains('command-palette-backdrop'))
  await waitUntil(backdropFocused, 'the palette backdrop taking focus')
  if (spec.step === 'placement') {
    await page.keyboard.press('Enter')
    await waitUntil(
      () =>
        page.evaluate(
          () =>
            document.querySelectorAll('.command-palette-item').length === 4 &&
            document.activeElement?.classList.contains('command-palette-backdrop')
        ),
      'the placement step'
    )
  }
  for (let i = 0; i < (spec.highlight ?? 0); i++) await page.keyboard.press('ArrowDown')
  if (spec.hover !== undefined) {
    const box = await page.locator('.command-palette-item').nth(spec.hover).boundingBox()
    if (!box) throw new Error(`palette: no row ${spec.hover} to hover`)
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  }
  await page.waitForTimeout(SETTLE_MS)
  const expected = spec.hover ?? spec.highlight ?? 0
  const state = await page.evaluate(async () => {
    const { useCommandPaletteStore } = await import('/src/core/store/commandPaletteStore.ts')
    const rows = [...document.querySelectorAll('.command-palette-item')]
    return {
      step: useCommandPaletteStore.getState().step.kind,
      rows: rows.length,
      highlighted: rows.flatMap((row, i) =>
        row.classList.contains('command-palette-item-highlighted') ? [i] : []
      )
    }
  })
  if (state.step !== spec.step)
    throw new Error(`palette: on step ${state.step}, wanted ${spec.step}`)
  if (state.rows > 0 && (state.highlighted.length !== 1 || state.highlighted[0] !== expected))
    throw new Error(`palette: highlighted ${state.highlighted}, wanted ${expected}`)
  return state.step
}

async function waitUntil(check, what, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise((done) => setTimeout(done, 50))
  }
}

const nextFrames = () =>
  new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)))

async function captureScenario(browser, origin, scenario, outDir) {
  const theme = scenario.settings?.colorTheme === 'light' ? 'light' : 'dark'
  const context = await browser.newContext({
    viewport: scenario.size,
    deviceScaleFactor: DEVICE_SCALE_FACTOR,
    colorScheme: theme,
    // The git tree's dates are formatted in local time. No other scenario shows one.
    timezoneId: 'UTC'
  })
  try {
    const page = await context.newPage()
    const errors = []
    page.on('pageerror', (error) => errors.push(error.message))
    const [gitTreeId, gitTreeSpec] = Object.entries(scenario.gitTree ?? {})[0] ?? []
    const { select: _select, ...gitTreeSeed } = gitTreeSpec ?? {}
    // The browser stand-in takes everything but `focusAddress`, which is the
    // capture's own step.
    const browserSeeds = Object.fromEntries(
      Object.entries(scenario.browser ?? {}).map(([id, { focusAddress: _focus, ...seed }]) => [
        id,
        seed
      ])
    )
    await page.addInitScript(
      ({ seed, gitTree, browserCapture, paletteTypes }) => {
        window.__tabsTestSeed = seed
        window.__tabsTestExtraContent = []
        if (gitTree) window.__tabsVisualGitTree = gitTree
        if (browserCapture) window.__tabsVisualBrowser = browserCapture
        if (paletteTypes !== undefined) window.__tabsVisualPaletteTypes = paletteTypes
      },
      {
        seed: { settings: scenario.settings ?? {}, layout: scenario.layout },
        gitTree: gitTreeSpec ? gitTreeSeed : undefined,
        browserCapture:
          scenario.browser || scenario.creationActions
            ? {
                panes: browserSeeds,
                createAction: scenario.creationActions?.includes('browser') === true
              }
            : undefined,
        paletteTypes: scenario.paletteTypes
      }
    )
    await page.goto(`${origin}/harness.html`)
    await page.waitForSelector('[data-testid="pane"]', { timeout: 20_000 })
    if (!scenario.tooltip) await page.addStyleTag({ content: HIDE_TOOLTIPS_CSS })
    await page.evaluate(() => document.fonts.ready)
    await page.evaluate(nextFrames)

    const gitTreeArgs = gitTreeSpec && {
      id: gitTreeId,
      spec: gitTreeSpec,
      collapsed: findLayoutNode(scenario.layout, gitTreeId).config?.detailCollapsed === true,
      rowsOnly: false
    }
    if (gitTreeSpec) {
      const args = gitTreeArgs
      if (gitTreeSpec.select !== undefined) {
        await waitForGitTree(page, { ...args, rowsOnly: true })
        // A click event rather than a mouse click, which would leave the
        // pointer over the row (hovered).
        await page.evaluate(
          ({ id, hash }) => {
            const pane = document.querySelector(`.pane[data-dock-id="${CSS.escape(id)}"]`)
            pane.querySelector(`.git-tree-row[data-hash="${CSS.escape(hash)}"]`).click()
          },
          { id: gitTreeId, hash: gitTreeSpec.select }
        )
      }
      await waitForGitTree(page, args)
      await page.evaluate(nextFrames)
    }
    const browserArgs = scenario.browser && {
      seeds: scenario.browser,
      urls: Object.fromEntries(
        Object.keys(scenario.browser).map((id) => [
          id,
          findLayoutNode(scenario.layout, id).config?.url ?? 'about:blank'
        ])
      ),
      titles: Object.fromEntries(
        Object.keys(scenario.browser).map((id) => [id, findLayoutNode(scenario.layout, id).title])
      )
    }
    if (browserArgs) {
      // Focus is a script call, so the pointer stays away from the field.
      await waitForBrowser(page, {
        ...browserArgs,
        seeds: Object.fromEntries(
          Object.entries(browserArgs.seeds).map(([id, spec]) => [
            id,
            { ...spec, focusAddress: false }
          ])
        )
      })
      for (const [id, spec] of Object.entries(scenario.browser)) {
        if (!spec.focusAddress) continue
        await page.evaluate((paneId) => {
          const pane = document.querySelector(`.pane[data-dock-id="${CSS.escape(paneId)}"]`)
          pane.querySelector('.browser-address-input').focus()
        }, id)
      }
      await waitForBrowser(page, browserArgs)
    }
    if (scenario.signals) await page.evaluate(seedSignals, scenario.signals)
    if (scenario.caffeinate) {
      // The managed process running: main broadcasts it over IPC.
      await page.evaluate(() => window.__fakeApi?.emitCaffeinateRunningChanged(true))
      await page.waitForSelector('[data-testid="caffeinate-decaf-button"]', { timeout: 5_000 })
    }
    if (scenario.fullscreen) {
      // The native (traffic-light) fullscreen: main pushes it over IPC.
      await page.evaluate(() => window.__fakeApi?.emitFullScreenChange(true))
    }
    if (scenario.contextMenu) {
      await page.mouse.click(scenario.contextMenu.x, scenario.contextMenu.y, { button: 'right' })
    }
    let paletteStepKind = null
    if (scenario.palette) paletteStepKind = await drivePalette(page, scenario.palette)
    if (scenario.pointer) {
      await page.mouse.move(scenario.pointer.x, scenario.pointer.y)
    }
    if (scenario.drag) {
      const { from, to } = scenario.drag
      await page.mouse.move(from.x, from.y)
      await page.mouse.down()
      await page.mouse.move(to.x, to.y, { steps: DRAG_STEPS })
    }
    await page.waitForTimeout(SETTLE_MS)
    if (scenario.tooltip) {
      await page.waitForSelector('.tooltip-bubble', { timeout: 5_000 })
      await page.waitForTimeout(SETTLE_MS)
    }
    if (scenario.signals) {
      const problems = await page.evaluate(signalMismatches, {
        signals: scenario.signals,
        settings: scenario.settings ?? {},
        kinds: SIGNALS
      })
      if (problems.length) throw new Error(`signals not shown as seeded: ${problems.join('; ')}`)
    }
    if (gitTreeArgs) {
      // Still as seeded once the pointer step has settled.
      const problems = await page.evaluate(gitTreeProblems, gitTreeArgs)
      if (problems.length)
        throw new Error(`git tree changed while settling: ${problems.join('; ')}`)
    }
    if (browserArgs) {
      const problems = await page.evaluate(browserProblems, browserArgs)
      if (problems.length) throw new Error(`browser changed while settling: ${problems.join('; ')}`)
    }
    // Without `pulse`, Playwright's `animations: 'disabled'` cancels the
    // infinite cue pulses, which leaves them at their un-animated opacity 1 —
    // the pulse's peak. With it, every animation is held at that time instead,
    // and the screenshot must leave them alone.
    if (scenario.pulse !== undefined) {
      const frozen = await page.evaluate(freezeAnimations, scenario.pulse * 1000)
      if (!frozen.length) throw new Error('pulse: no animation to freeze')
      await page.evaluate(nextFrames)
    }

    const geometry = await page.evaluate(collectGeometry, paletteStepKind)
    await page.screenshot({
      path: join(outDir, `${scenario.name}.png`),
      animations: scenario.pulse === undefined ? 'disabled' : 'allow'
    })
    writeFileSync(
      join(outDir, `${scenario.name}.geometry.json`),
      formatJson({ scenario: scenario.name, ...geometry })
    )
    if (scenario.drag) await page.mouse.up()
    if (errors.length) throw new Error(`page errors: ${errors.join('; ')}`)
    return geometry
  } finally {
    await context.close()
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  const scenarios = loadScenarios(options.names)
  mkdirSync(options.out, { recursive: true })

  // vite.harness.config.ts and alias.config.ts resolve paths against the cwd.
  process.chdir(REPO_ROOT)
  const [{ createServer }, { chromium }] = await Promise.all([import('vite'), import('playwright')])
  const port = await freePort()
  const server = await createServer({
    configFile: join(REPO_ROOT, 'vite.harness.config.ts'),
    logLevel: 'warn',
    server: { host: '127.0.0.1', port, strictPort: true, hmr: false }
  })
  let browser
  try {
    await server.listen()
    const origin = `http://127.0.0.1:${port}`
    browser = await chromium.launch({ headless: !options.headed })

    // Warm-up: vite pre-bundles dependencies on first request and may reload
    // the page once it has; absorb that here rather than in a scenario.
    {
      const page = await browser.newPage()
      await page.goto(`${origin}/harness.html`)
      await page.waitForSelector('[data-testid="pane"]', { timeout: 60_000 })
      await page.waitForLoadState('networkidle')
      await page.close()
    }

    let failures = 0
    for (const scenario of scenarios) {
      try {
        const geometry = await captureScenario(browser, origin, scenario, options.out)
        console.log(
          `ok   ${scenario.name.padEnd(22)} ${Object.keys(geometry.panes).length} panes, ${Object.keys(geometry.tabBars).length} tab bars`
        )
      } catch (error) {
        failures++
        console.error(`FAIL ${scenario.name}: ${error.message}`)
      }
    }
    console.log(
      `wrote ${scenarios.length - failures}/${scenarios.length} scenarios to ${options.out}`
    )
    process.exitCode = failures > 0 ? 1 : 0
  } finally {
    await browser?.close()
    await server.close()
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
