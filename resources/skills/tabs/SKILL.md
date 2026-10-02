---
name: tabs
description: Drive panes in the Tabs terminal app from a shell running inside one of its terminal panes — today, browser panes: open one, screenshot a page, read its text or structure, click and type, capture console and network activity, run JavaScript. Discover the full surface with the tool itself. Only relevant when the user is working inside Tabs — do not reach for this in any other terminal.
# allowed-tools is a real optional field in the open Agent Skills spec
# (agentskills.io/specification: "Experimental. Support for this field may
# vary between agent implementations") — not a Claude Code-only extension.
# It pre-approves the two printenv calls below so Claude Code runs them
# without a permission prompt; an agent that doesn't implement it is
# expected to just ignore an optional key it doesn't recognize.
allowed-tools: Bash(printenv TABS_CONTROL_SOCKET), Bash(printenv TABS_PANE_ID)
---

# Controlling Tabs

This skill lets you create and drive panes inside the Tabs app (the terminal app this shell may be running in) — today, browser panes; other content types add their own capabilities to the same tool over time. It only works from a terminal pane Tabs itself spawned — check before doing anything else.

## Check you're actually inside Tabs

Run these two commands yourself before doing anything else:

```
printenv TABS_CONTROL_SOCKET
printenv TABS_PANE_ID
```

If either command fails or prints nothing, **stop** — this shell is not running inside a Tabs terminal pane, so none of the commands below will work. Tell the user this skill only applies inside the Tabs app and do nothing further.

If both values are present, continue below.

## How this works

Run everything via `${CLAUDE_SKILL_DIR}/scripts/tabs-ctl <command> [options]`.

Every command prints one line of JSON and exits 0 on success, or prints `{"ok":false,"error":"..."}` and exits non-zero on failure. Read the error and relay it plainly rather than retrying blindly.

Flags take a value as `--flag value` or `--flag=value`; use the `=` form for a value that itself starts with `--`.

## Discovering what's available

```
tabs-ctl capabilities
tabs-ctl describe --capability <name>
```

`capabilities` lists every capability this app has right now — `core` (the commands below) plus one per content type (`browser`, and others as they add their own) — each with whether it's enabled and a one-line index of its commands. `describe` gives one capability's full reference: every command's flags, its exact wire shape (JSON Schema — what a `batch` step for it looks like), its result shape, and that capability's **guide**, the prose that explains *when* and *how* to use its commands well, not just what they accept.

Both need a live socket, same as everything else here — nothing in this skill works offline, including discovery.

**Read a capability's guide before you use it for the first time in a session.** The flag list tells you what a command accepts; the guide tells you the things that aren't obvious from that alone — readiness semantics, targeting rules, what to poll for, what commonly goes wrong. `tabs-ctl describe --capability browser` is where browser-pane driving actually lives now; this file no longer restates it.

Trust `describe`'s output over any prose, this file included, when the two disagree — it is generated from the same specs the app validates your calls against, so it cannot drift the way documentation can.

## Ownership

**You can only act on panes you created.** A creation command (`create-browser-pane`, and any future content type's own) returns a `paneId`; that is the only pane you may target, and for as long as the app keeps running — including after the user has since navigated that same pane somewhere else by hand. A pane the user opened by hand, or one another terminal created, is refused with `not the owner of this pane`.

What ownership does **not** do is keep the pane alive: the user can close it by hand at any time, and nothing tells you when they do. Every verb aimed at it then fails with

```
target pane no longer exists — it was closed; listOwnedPanes shows the panes still open
```

Treat that as ordinary, not as an error to retry or work around — it usually means the user closed the pane deliberately. Run `list-panes` to see what's still open, and create a fresh pane if you still need one.

You get **the same message** for a pane you closed yourself with `close-pane`, which is the other way an id stops working. It is not `not the owner of this pane` — that message is reserved for an id that was never yours, and reading it after your own `close-pane` would send you looking for a permissions problem that doesn't exist.

Close panes you no longer need (`close-pane --pane <id>`) rather than leaving them on the user's screen — it also gives up ownership of the id.

## Several requests at once

```
tabs-ctl batch --requests '<json>' [--continue-on-error]
```

`--requests` is a JSON array of raw wire requests — camelCase `type`, `targetPaneId` instead of `--pane`, no `paneId` (the app fills that in). **Don't guess the shape — `describe --capability <name>` prints it** for every command, under `wire`. A command's wire `type` is not always its CLI name spelled differently (a capability's `describe` output is the source of truth, never a transliteration).

Returns a transcript: `{"steps":[...]}`, one entry per request in the same order, each `{"type","ok","durationMs",...}` with that step's own result or error inline. Requests run **sequentially** and the batch **stops at the first failure** by default — `stoppedAt` names the index, and every later entry is `{"type","skipped":true}` rather than absent, so `steps[i]` always describes `requests[i]`. `--continue-on-error` runs every step regardless, for a batch of independent reads where one failure shouldn't discard the rest. Either way the exit code reflects whether every step succeeded.

At most 50 requests per batch, and a batch cannot contain another batch. A capability's guide names any of its own commands that can't appear in one (the browser's `create-browser-pane` is the current example — see why in its guide).

With a capability's own waiting/asserting commands as steps, batch is the normal way to drive a sequence, not an optimization for special cases: act, wait for the effect, assert the premise, read — one call, one transcript, instead of one process spawn per step plus guessed sleeps between them.

## Files, never bytes

Any command whose answer would otherwise be large or binary — a screenshot, a saved resource, an oversized script result — writes it to a local file and returns the **path**, never the bytes inline. Read the file with your normal file-reading tools. This is deliberate, not a size accident: your own stdout is the calling agent's context, and a megabyte of base64 or truncated text there is worse than useless. A capability's guide says which of its commands work this way and what the file-lifetime rules are (typically: swept automatically after a short while, so read promptly).
