import type { ControlVerbSpec, FlagSpec } from '@tabs/plugin-sdk/shared/content/controlSpec'
import type { JsonSchema } from '@tabs/plugin-sdk/shared/jsonSchema'
import type { BrowserControlRequest } from './externalControl'
import {
  DEFAULT_PAGE_TEXT_MAX,
  EDITING_COMMANDS,
  EXECUTE_RESULT_MAX,
  NETWORK_BODY_HARD_MAX,
  NETWORK_BODY_MAX,
  PAGE_TEXT_HARD_MAX,
  WAIT_DEFAULT_POLL_MS,
  WAIT_DEFAULT_TIMEOUT_MS,
  WAIT_IDLE_QUIET_MS,
  WAIT_MAX_TIMEOUT_MS
} from './externalControl'
import { NETWORK_METHODS, NETWORK_RESOURCE_TYPES } from './networkVocabulary'

/**
 * The browser package's external-control verbs, one `ControlVerbSpec` per
 * verb — the straight port of what used to be `tabs-ctl`'s own hand-written
 * `COMMANDS` table (see resources/skills/tabs/scripts/tabs-ctl before this
 * ticket). The CLI now ships none of this; `capabilities`/`describe` serve
 * it from here, and `src/main/controlEnvelope.ts` coerces a caller's flags
 * against it before dispatch.
 *
 * Every entry's `verb` is checked against this package's own
 * `BrowserControlRequest` union by the reconciliation test
 * (src/shared/plugin/__tests__/manifestReconciliation.test.ts), so a verb
 * added to one without the other fails a test rather than shipping silently
 * wrong.
 */

const PANE_FLAG: FlagSpec = { wire: 'targetPaneId', required: true, doc: 'A pane id you own.' }

/**
 * A `path`-typed flag's wire value is `string | true` (`true` meaning "the
 * app generates one" — see `FlagSpec.type`'s doc), so its schema is
 * deliberately empty rather than `{ type: 'string' }`: a real, generated
 * path validation gave every bare `--out` a false "must be a string (got
 * boolean)" refusal, since coercion had correctly sent `true` and the schema
 * only allowed a string. An empty schema still satisfies
 * `additionalProperties: false` (the property is declared) while imposing no
 * type check on it.
 */
const PATH_FIELD_SCHEMA: JsonSchema = {}

/** Every request wire shape shares this much: an object, the verb's own `type`, and `targetPaneId`. `paneId` never appears — the app fills it in. */
function requestSchema(
  verb: string,
  properties: Record<string, JsonSchema>,
  required: readonly string[] = []
): JsonSchema {
  return {
    type: 'object',
    properties: { type: { const: verb }, targetPaneId: { type: 'string' }, ...properties },
    required: ['type', 'targetPaneId', ...required],
    additionalProperties: false
  }
}

/** `ElementTarget`'s wire shape — ref, coordinate, or semantic (role/name/selector, at least one, plus optional nth). */
const TARGET_SCHEMA: JsonSchema = {
  oneOf: [
    {
      type: 'object',
      properties: { ref: { type: 'string' } },
      required: ['ref'],
      additionalProperties: false
    },
    {
      type: 'object',
      properties: { x: { type: 'number' }, y: { type: 'number' } },
      required: ['x', 'y'],
      additionalProperties: false
    },
    {
      type: 'object',
      properties: {
        role: { type: 'string' },
        name: { type: 'string' },
        selector: { type: 'string' },
        nth: { type: 'number' }
      },
      anyOf: [
        { type: 'object', required: ['role'] },
        { type: 'object', required: ['name'] },
        { type: 'object', required: ['selector'] }
      ],
      additionalProperties: false
    }
  ]
}

/** "a, b, or c" — how a flag doc lists an accepted vocabulary, matching the old CLI's own `listOf`. */
function listOf(values: readonly string[]): string {
  return `${values.slice(0, -1).join(', ')}, or ${values[values.length - 1]}`
}

const TARGET_FLAGS = {
  ref: { doc: 'An opaque ref from a previous read-page/find.' },
  x: { type: 'number', doc: 'Viewport CSS-pixel x — pair with --y.' },
  y: { type: 'number', doc: 'Viewport CSS-pixel y — pair with --x.' },
  role: { doc: 'Match by ARIA role (button, link, textbox, …), combined with --name/--selector.' },
  name: { doc: 'Match by accessible name, combined with --role/--selector.' },
  selector: { placeholder: 'css', doc: 'Match by CSS selector, combined with --role/--name.' },
  nth: { type: 'number', min: 0, doc: '0-based pick among several matches of the strictest tier.' }
} as const satisfies Record<string, FlagSpec>

const RECT = {
  x: 'number',
  y: 'number',
  width: 'number',
  height: 'number'
}

const PAGE_STATE = {
  isLoading: 'boolean',
  readyState: 'string',
  settled: 'boolean',
  frames: 'number',
  shadowRoots: 'number'
}

const SETTLED_PAGE = {
  url: 'string',
  title: 'string',
  titleFromUrl: 'boolean',
  status: 'number',
  statusText: 'string'
}

/**
 * Keyed by verb name rather than a plain array, so this is checked against
 * `BrowserControlRequest['type']` at compile time — a verb added to the
 * union without a spec entry here fails to build, and an entry naming a
 * verb the union no longer has fails too. The same exhaustiveness
 * `BROWSER_CONTROL_REQUEST_MARKER` used to give, now carrying the actual
 * spec rather than a bare `true`.
 */
const BROWSER_CONTROL_VERB_SPEC_TABLE: {
  [V in BrowserControlRequest['type']]: ControlVerbSpec
} = {
  createBrowserPane: {
    verb: 'createBrowserPane',
    command: 'create-browser-pane',
    summary:
      'Open a browser pane and wait for its first page. Where it appears relative to the pane you are running in — a new tab (the default), a split, or its own unpinned window — is the user\'s setting (Settings → Browser → "New pane placement"), not a per-call choice. The returned paneId is the only pane you may target.',
    flags: { url: { required: true, doc: 'http://, https://, or about:blank.' } },
    wire: {
      type: 'object',
      properties: { type: { const: 'createBrowserPane' }, url: { type: 'string' } },
      required: ['type', 'url'],
      additionalProperties: false
    },
    batchable: false,
    result: {
      paneId: 'string',
      loaded: 'boolean',
      loadError: 'string',
      ...SETTLED_PAGE,
      redirected: 'boolean'
    }
  },
  navigate: {
    verb: 'navigate',
    command: 'navigate',
    summary:
      'Load a URL into a pane you own and wait for it to settle. Reports where the pane actually ended up. Fails with the ERR_* code if the page cannot load.',
    flags: {
      pane: PANE_FLAG,
      url: { required: true, doc: 'http://, https://, or about:blank.' },
      'retry-on-redirect': {
        wire: 'retryOnRedirect',
        type: 'boolean',
        doc: 'Re-issue the navigation once if it lands somewhere other than the requested URL (an auth bounce). The result then carries retried and firstUrl.'
      }
    },
    wire: requestSchema(
      'navigate',
      { url: { type: 'string' }, retryOnRedirect: { type: 'boolean' } },
      ['url']
    ),
    result: {
      loaded: 'boolean',
      ...SETTLED_PAGE,
      redirected: 'boolean',
      retried: 'boolean',
      firstUrl: 'string'
    }
  },
  reload: {
    verb: 'reload',
    command: 'reload',
    summary: 'Reload the current page and wait for it to settle.',
    flags: { pane: PANE_FLAG },
    wire: requestSchema('reload', {}),
    result: { loaded: 'boolean', loadError: 'string', ...SETTLED_PAGE }
  },
  goBack: {
    verb: 'goBack',
    command: 'go-back',
    summary: 'Go back one page in the pane’s history and wait for it to settle.',
    flags: { pane: PANE_FLAG },
    wire: requestSchema('goBack', {}),
    result: { loaded: 'boolean', loadError: 'string', ...SETTLED_PAGE }
  },
  goForward: {
    verb: 'goForward',
    command: 'go-forward',
    summary: 'Go forward one page in the pane’s history and wait for it to settle.',
    flags: { pane: PANE_FLAG },
    wire: requestSchema('goForward', {}),
    result: { loaded: 'boolean', loadError: 'string', ...SETTLED_PAGE }
  },
  screenshot: {
    verb: 'screenshot',
    command: 'screenshot',
    summary:
      'Capture the pane, bringing it to the front first if it’s backgrounded (reported as activated: true). Returns a PNG path to read, never inline image data.',
    flags: {
      pane: PANE_FLAG,
      'no-activate': {
        wire: 'noActivate',
        type: 'boolean',
        doc: 'Fail on a backgrounded pane instead of bringing it to the front.'
      },
      selector: {
        placeholder: 'css',
        doc: 'Clip the capture to this element instead of the whole viewport. Scrolled into view first; clamped to what the guest is showing.'
      },
      ref: { doc: 'Clip to a read-page/find ref, like --selector.' }
    },
    wire: requestSchema('screenshot', {
      noActivate: { type: 'boolean' },
      selector: { type: 'string' },
      ref: { type: 'string' }
    }),
    result: {
      path: 'string',
      width: 'number',
      height: 'number',
      viewport: { width: 'number', height: 'number' },
      scaleFactor: 'number',
      clipped: RECT,
      element: { role: 'string', name: 'string', tag: 'string' },
      activated: 'boolean'
    }
  },
  getPageText: {
    verb: 'getPageText',
    command: 'get-page-text',
    summary: 'Rendered page text (innerText — no script or style bodies).',
    flags: {
      pane: PANE_FLAG,
      'max-length': {
        wire: 'maxLength',
        type: 'number',
        min: 1,
        doc: `Default ${DEFAULT_PAGE_TEXT_MAX}, capped at ${PAGE_TEXT_HARD_MAX}.`
      }
    },
    wire: requestSchema('getPageText', { maxLength: { type: 'number', minimum: 1 } }),
    result: { text: 'string', truncated: 'boolean', ...PAGE_STATE }
  },
  readPage: {
    verb: 'readPage',
    command: 'read-page',
    summary:
      'Interactive elements and headings, each with a ref for click/type. Capped at 200 per call — narrow with --selector/--role or page with --offset.',
    flags: {
      pane: PANE_FLAG,
      selector: {
        placeholder: 'css',
        doc: "Extract this selector's matches instead of the default interactive set — the way to reach elements it never lists, images (img[alt]) especially."
      },
      role: {
        doc: 'Only elements with this role (button, link, textbox, combobox, checkbox, heading, …). A hard filter: it never widens on its own.'
      },
      offset: {
        type: 'number',
        min: 0,
        doc: 'Skip this many matches before the page returned. Use with total/truncated to walk a long page.'
      }
    },
    wire: requestSchema('readPage', {
      selector: { type: 'string' },
      role: { type: 'string' },
      offset: { type: 'number', minimum: 0 }
    }),
    result: {
      elements: [
        {
          ref: 'string',
          role: 'string',
          name: 'string',
          tag: 'string',
          rect: RECT,
          value: 'string',
          checked: 'boolean | "mixed"'
        }
      ],
      total: 'number',
      offset: 'number',
      truncated: 'boolean',
      ...PAGE_STATE
    }
  },
  find: {
    verb: 'find',
    command: 'find',
    summary: 'Best-effort search over read-page’s elements. Heuristic, not semantic.',
    flags: {
      pane: PANE_FLAG,
      description: { required: true, placeholder: 'text' },
      'max-results': { wire: 'maxResults', type: 'number', min: 1 }
    },
    wire: requestSchema(
      'find',
      { description: { type: 'string' }, maxResults: { type: 'number', minimum: 1 } },
      ['description']
    ),
    result: {
      matches: [
        {
          ref: 'string',
          name: 'string',
          role: 'string',
          tag: 'string',
          rect: RECT,
          score: 'number'
        }
      ],
      ...PAGE_STATE
    }
  },
  click: {
    verb: 'click',
    command: 'click',
    summary:
      'Click an element or a viewport coordinate, with real mouse events. A ref is re-checked at dispatch time and the result reports the element hit.',
    flags: { pane: PANE_FLAG, ...TARGET_FLAGS },
    targetCompose: 'elementTarget',
    wire: requestSchema('click', { target: TARGET_SCHEMA }, ['target']),
    result: { x: 'number', y: 'number', element: { role: 'string', name: 'string', tag: 'string' } }
  },
  hover: {
    verb: 'hover',
    command: 'hover',
    summary:
      'Move the pointer onto an element without pressing it — for a menu that opens on hover but navigates on click. Read the page afterwards to see what appeared.',
    flags: { pane: PANE_FLAG, ...TARGET_FLAGS },
    targetCompose: 'elementTarget',
    wire: requestSchema('hover', { target: TARGET_SCHEMA }, ['target']),
    result: { x: 'number', y: 'number', element: { role: 'string', name: 'string', tag: 'string' } }
  },
  type: {
    verb: 'type',
    command: 'type',
    summary: 'Type text at the target. Appends — use form-input to replace a value.',
    flags: {
      pane: PANE_FLAG,
      ...TARGET_FLAGS,
      text: {
        required: true,
        doc: 'Printable text only — a newline/tab/control character is refused (keystrokes cannot carry it); use form-input for multiline values.'
      },
      submit: {
        type: 'boolean',
        doc: 'Press Enter after the text — a full keydown/keypress/keyup, so a plain form submits as it would for a physical Enter.'
      }
    },
    targetCompose: 'elementTarget',
    wire: requestSchema(
      'type',
      { target: TARGET_SCHEMA, text: { type: 'string' }, submit: { type: 'boolean' } },
      ['target', 'text']
    )
  },
  key: {
    verb: 'key',
    command: 'key',
    summary:
      "Send one key (Enter, Escape, Tab, ArrowLeft, a), or run one of the browser's own editing commands with --command. A modifier chord cannot reach those — see --command.",
    flags: {
      pane: PANE_FLAG,
      key: { doc: 'The key to press, e.g. Enter, Escape, Tab, ArrowLeft, a.' },
      modifiers: {
        type: 'csv',
        placeholder: 'shift,control,alt,meta',
        doc: 'Keys held during the press. With meta or control held no keypress is sent — the chord produces no character, as best measured of a physical keyboard on macOS.'
      },
      command: {
        enum: EDITING_COMMANDS,
        doc: 'Run an editing command through the browser itself, which a synthesized Cmd+A/Cmd+Z cannot reach. Acts on whatever the page has focused. Clipboard commands are deliberately not offered.'
      }
    },
    wire: requestSchema('key', {
      key: { type: 'string' },
      modifiers: { type: 'array', items: { enum: ['shift', 'control', 'alt', 'meta'] } },
      command: { enum: [...EDITING_COMMANDS] }
    }),
    result: {
      command: 'string',
      element: { role: 'string', name: 'string', tag: 'string' },
      note: 'string'
    }
  },
  scroll: {
    verb: 'scroll',
    command: 'scroll',
    summary:
      'Scroll the page and report where it landed. Instantaneous even on a smooth-scrolling page, so the reported position is the settled one. Does not scroll a nested scrollable container.',
    flags: {
      pane: PANE_FLAG,
      direction: { default: 'down', enum: ['up', 'down', 'left', 'right'] },
      amount: { type: 'number', min: 1, placeholder: 'px', doc: 'Defaults to about one screen.' }
    },
    wire: requestSchema(
      'scroll',
      {
        direction: { enum: ['up', 'down', 'left', 'right'] },
        amount: { type: 'number', minimum: 1 }
      },
      ['direction']
    ),
    result: { position: { x: 'number', y: 'number' } }
  },
  formInput: {
    verb: 'formInput',
    command: 'form-input',
    summary:
      'Set field values verbatim (multiline safe), replacing existing contents. Exits non-zero when any field failed.',
    flags: {
      pane: PANE_FLAG,
      fields: { type: 'json', required: true, doc: 'A JSON array of {target, value} pairs.' }
    },
    wire: requestSchema(
      'formInput',
      {
        fields: {
          type: 'array',
          items: {
            type: 'object',
            properties: { target: TARGET_SCHEMA, value: { type: 'string' } },
            required: ['target', 'value'],
            additionalProperties: false
          }
        }
      },
      ['fields']
    ),
    result: {
      filled: 'number',
      fields: [{ index: 'number', length: 'number' }],
      errors: [{ index: 'number', error: 'string' }]
    }
  },
  readConsoleMessages: {
    verb: 'readConsoleMessages',
    command: 'read-console',
    summary: 'Captured console output for the current page. Cleared on navigation.',
    flags: {
      pane: PANE_FLAG,
      pattern: {
        placeholder: 'regex',
        doc: 'Regular expression; a pattern that fails to parse is refused rather than matched as literal text.'
      },
      'since-seq': {
        wire: 'sinceSeq',
        type: 'number',
        min: 0,
        doc: 'Return only messages after this seq.'
      }
    },
    wire: requestSchema('readConsoleMessages', {
      pattern: { type: 'string' },
      sinceSeq: { type: 'number', minimum: 0 }
    }),
    result: {
      messages: [
        {
          seq: 'number',
          level: 'string',
          text: 'string',
          timestamp: 'number',
          sourceURL: 'string',
          line: 'number'
        }
      ]
    }
  },
  readNetworkRequests: {
    verb: 'readNetworkRequests',
    command: 'read-network',
    summary:
      'Request metadata for the current page; response bodies too, once capture-bodies is on and --with-bodies is passed.',
    flags: {
      pane: PANE_FLAG,
      pattern: {
        placeholder: 'regex',
        doc: 'Regular expression; a pattern that fails to parse is refused rather than matched as literal text.'
      },
      method: {
        placeholder: 'verb',
        doc: `Only this HTTP method (case-insensitive): ${listOf(NETWORK_METHODS)}.`
      },
      status: {
        placeholder: 'spec',
        doc: 'Only these statuses: an exact code (404), a class (4xx), or a range (400-499).'
      },
      failed: {
        type: 'boolean',
        doc: 'Only failures: a 4xx/5xx status or a network error. Start here when something broke.'
      },
      'resource-type': {
        wire: 'resourceType',
        placeholder: 'type',
        doc: `Only this resource type: ${listOf(NETWORK_RESOURCE_TYPES)}. fetch and XMLHttpRequest traffic both report as xhr.`
      },
      'since-seq': {
        wire: 'sinceSeq',
        type: 'number',
        min: 0,
        doc: 'Return only requests after this seq.'
      },
      unredacted: { type: 'boolean', doc: 'Return credential headers in full. Use sparingly.' },
      'with-bodies': {
        wire: 'withBodies',
        type: 'boolean',
        doc: 'Attach captured response bodies (needs capture-bodies on first). Combine with --pattern.'
      },
      brief: {
        type: 'boolean',
        doc: 'Drop the header maps, keeping seq/method/url/resourceType/status/timings. The readable form for "what happened on this page".'
      },
      out: {
        wire: 'outPath',
        type: 'path',
        placeholder: 'path',
        doc: "Write the whole result to a file instead of returning it inline; returns {path, bytes, count}. Resolved against your shell's cwd and never overwritten; bare --out generates a temp file swept after ~10 minutes."
      },
      'body-seq': {
        wire: 'bodySeq',
        type: 'number',
        min: 0,
        doc: 'With --body-out: which entry’s body to write, by its seq from a previous read.'
      },
      'body-out': {
        wire: 'bodyOutPath',
        type: 'path',
        placeholder: 'path',
        doc: 'Write one entry’s captured response body to a file (needs --body-seq); answers {path, bytes, seq, truncated, size}. Only what capture retained can be written — truncated: true means the body was cut at the capture limit as it arrived, and size is the response’s full length; raise capture-bodies --max-body before the request to keep more. Also the route for a body whose endpoint 404s on the GET save-resource would issue.'
      }
    },
    wire: requestSchema('readNetworkRequests', {
      pattern: { type: 'string' },
      method: { type: 'string' },
      status: { type: 'string' },
      failed: { type: 'boolean' },
      resourceType: { type: 'string' },
      sinceSeq: { type: 'number', minimum: 0 },
      unredacted: { type: 'boolean' },
      withBodies: { type: 'boolean' },
      brief: { type: 'boolean' },
      outPath: PATH_FIELD_SCHEMA,
      bodySeq: { type: 'number', minimum: 0 },
      bodyOutPath: PATH_FIELD_SCHEMA
    }),
    result: {
      requests: [
        {
          seq: 'number',
          method: 'string',
          url: 'string',
          resourceType: 'string',
          status: 'number',
          error: 'string',
          startedAt: 'number',
          completedAt: 'number',
          count: 'number',
          firstStartedAt: 'number',
          requestHeaders: 'object',
          responseHeaders: 'object',
          responseBody: {
            body: 'string',
            truncated: 'boolean',
            size: 'number',
            mimeType: 'string',
            binary: 'boolean'
          }
        }
      ],
      bodyCapture: 'string',
      path: 'string',
      bytes: 'number',
      count: 'number',
      seq: 'number',
      truncated: 'boolean',
      size: 'number'
    }
  },
  captureNetworkBodies: {
    verb: 'captureNetworkBodies',
    command: 'capture-bodies',
    summary:
      'Start retaining response bodies for a pane, from now on — then act (or reload) and read them with read-network --with-bodies. Attaches a debugger to the pane; --off detaches and stops.',
    flags: {
      pane: PANE_FLAG,
      off: {
        wire: 'enabled',
        type: 'boolean',
        value: false,
        doc: 'Stop capturing and detach. Already-captured bodies stay readable until the page navigates.'
      },
      'max-body': {
        wire: 'maxBodyChars',
        type: 'number',
        min: 1,
        doc: `Retain this many characters of each body instead of ${NETWORK_BODY_MAX} (ceiling ${NETWORK_BODY_HARD_MAX}). Applies from now on — a body is capped as it arrives and cannot be recovered afterwards — and costs memory for this pane, so raise it when you know a response is large.`
      }
    },
    wire: requestSchema('captureNetworkBodies', {
      enabled: { type: 'boolean' },
      maxBodyChars: { type: 'number', minimum: 1 }
    }),
    result: { enabled: 'boolean', maxBodyChars: 'number' }
  },
  executeJavaScript: {
    verb: 'executeJavaScript',
    command: 'execute-js',
    summary: 'Evaluate one expression in the page. Wrap statements in an IIFE.',
    flags: {
      pane: PANE_FLAG,
      code: { required: true, placeholder: 'expression' },
      out: {
        wire: 'outPath',
        type: 'path',
        placeholder: 'path',
        doc: `Write the full result to a file instead of truncating at ${EXECUTE_RESULT_MAX} chars; returns {path, bytes, format}. A string result is written raw, anything else as pretty-printed JSON. With a path it is resolved against your shell's cwd and never overwritten; bare --out generates a temp file swept after ~10 minutes.`
      }
    },
    wire: requestSchema(
      'executeJavaScript',
      { code: { type: 'string' }, outPath: PATH_FIELD_SCHEMA },
      ['code']
    ),
    result: {
      value: 'object',
      truncated: 'boolean',
      path: 'string',
      bytes: 'number',
      format: 'string'
    }
  },
  waitFor: {
    verb: 'waitFor',
    command: 'wait-for',
    summary:
      'Wait inside the page until a condition holds — one call in place of a sleep-and-poll loop. Exactly one of --text, --selector, --url-contains, --idle per call.',
    flags: {
      pane: PANE_FLAG,
      text: { placeholder: 'string', doc: 'Resolve when the rendered page text contains this.' },
      selector: {
        placeholder: 'css',
        doc: 'Resolve when this matches a visible element; reports its ref for click/type.'
      },
      gone: { type: 'boolean', doc: 'Invert --text/--selector: resolve when it stops holding.' },
      'url-contains': {
        wire: 'urlContains',
        placeholder: 'string',
        doc: 'Resolve when the pane’s URL contains this. Survives navigation, so it covers auth bounces and SPA routes.'
      },
      idle: {
        type: 'boolean',
        doc: `Resolve when the DOM stops mutating for ${WAIT_IDLE_QUIET_MS}ms — the fallback when nothing specific marks readiness.`
      },
      timeout: {
        wire: 'timeoutMs',
        type: 'number',
        placeholder: 'ms',
        doc: `Default ${WAIT_DEFAULT_TIMEOUT_MS}, capped at ${WAIT_MAX_TIMEOUT_MS}. Long waits also need the Bash tool timeout raised.`
      },
      poll: {
        wire: 'pollMs',
        type: 'number',
        placeholder: 'ms',
        doc: `Fallback check interval, default ${WAIT_DEFAULT_POLL_MS}; mutations are noticed immediately regardless.`
      }
    },
    wire: requestSchema('waitFor', {
      text: { type: 'string' },
      selector: { type: 'string' },
      gone: { type: 'boolean' },
      urlContains: { type: 'string' },
      idle: { type: 'boolean' },
      timeoutMs: { type: 'number' },
      pollMs: { type: 'number' }
    }),
    result: { elapsedMs: 'number', ref: 'string', tag: 'string', rect: RECT, url: 'string' }
  },
  assert: {
    verb: 'assert',
    command: 'assert',
    summary:
      'Check that a condition holds right now, failing (non-zero) when it doesn’t — the self-verifying step for a batch. Exactly one of --text, --selector, --url-contains.',
    flags: {
      pane: PANE_FLAG,
      text: { placeholder: 'string', doc: 'Assert the rendered page text contains this.' },
      selector: {
        placeholder: 'css',
        doc: 'Assert this matches a visible element; reports its ref for click/type.'
      },
      gone: { type: 'boolean', doc: 'Invert --text/--selector: assert it does not hold.' },
      'url-contains': {
        wire: 'urlContains',
        placeholder: 'string',
        doc: 'Assert the pane’s URL contains this.'
      }
    },
    wire: requestSchema('assert', {
      text: { type: 'string' },
      selector: { type: 'string' },
      gone: { type: 'boolean' },
      urlContains: { type: 'string' }
    }),
    result: { ref: 'string', tag: 'string', rect: RECT, url: 'string' }
  },
  saveResource: {
    verb: 'saveResource',
    command: 'save-resource',
    summary:
      'Save a page resource — a blob:/data:/http(s) URL, or an element’s src — to a local file and return the path (never the bytes). The way to get a PDF, image or any binary out of a page: save it, then read the file. Pass exactly one of --url, --ref, --selector.',
    flags: {
      pane: PANE_FLAG,
      url: { doc: 'A blob:, data:, http:, or https: URL to fetch.' },
      ref: { doc: 'A read-page ref whose element’s src/href is saved.' },
      selector: { placeholder: 'css', doc: 'A CSS selector whose element’s src/href is saved.' },
      out: {
        wire: 'outPath',
        type: 'path',
        placeholder: 'path',
        doc: 'Where to write it, resolved against your shell’s cwd. Default: a temp file swept after ~10 minutes.'
      }
    },
    wire: requestSchema('saveResource', {
      url: { type: 'string' },
      ref: { type: 'string' },
      selector: { type: 'string' },
      outPath: PATH_FIELD_SCHEMA
    }),
    result: { path: 'string', bytes: 'number', contentType: 'string' }
  }
}

export const BROWSER_CONTROL_VERB_SPECS: ControlVerbSpec[] = Object.values(
  BROWSER_CONTROL_VERB_SPEC_TABLE
)
