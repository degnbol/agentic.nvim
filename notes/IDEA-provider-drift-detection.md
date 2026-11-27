# Feature: detect provider drift

## Background

An adapter reads fields one build of one provider happens to emit. When the
provider changes, the adapter does not fail — it takes a fallback branch and
renders something plausible. claude-agent-acp 0.75.1 changed two tool display
titles, and the resulting loss of skill names, skill auto-approval and the
plan-exit permission option surfaced only when a user noticed a block looked
wrong, months later.

Two detectors are needed, because neither covers the other's cases.

**A version change has broad recall and no precision.** It fires on every
provider upgrade and says only that drift is possible. It catches the class no
other signal can: a rename that removes a display title and its redundant
partner together, a dropped `_meta` field, and each of the adapter's
title-keyed reads that has no partner at all — every `PLACEHOLDER_TITLES` entry,
the read-range regex in `__apply_raw_input`, and its
`suppress_placeholder_title` fallback.

**A contradiction has full precision and narrow recall.** Two signals from one
notification disagreeing means a specific branch failed, and says which. It
fires at the break rather than at the upgrade, and needs no record of which
build the adapter was written against. It requires the two signals to have
independent origins in the bridge: a pair that both derive from the tool name
cannot disagree, and a rename removes both at once.

The plugin already reports one member of the contradiction family.
`ACPClient:__handle_session_update` notifies when a `tool_call` carries a
`kind` outside `KNOWN_ACP_KINDS` — a provider declaring something the plugin
has no name for. It does not catch the converse: the provider declares
something the plugin *does* name, and the handler for it does not fire.

## Changes

### Version marker

Record the provider version last seen, per provider, and notify when the
version reported in the ACP `initialize` response differs from it.

Nothing about this needs maintaining: the baseline is what the previous run
observed. The trade against a source constant is real and worth naming — the
marker clears itself on the next connect whether or not anyone audited
anything, so a dismissed notice is gone for good. That buys freedom from a nag
at the cost of persistence, which is the right way round for a signal whose
job is to mark a moment.

A new `lua/agentic/acp/provider_versions.lua` owns the store:

- `M.recorded(provider)` → the version observed on the previous run, or `nil`.
- `M.record(provider, version)` — persist `version` as the last observed.

Both go through the existing `FileSystem` read/save/mkdirp helpers rather than
open-coding I/O; the initialize callback is already scheduled and the file is a
few hundred bytes. The comparison itself is string inequality and does not want
a function of its own — the part that can fail is the store.

Three states, not two:

- **Absent** — genuine first run. Record, say nothing.
- **Differing** — record, notify with both versions. No ordering claim is made,
  so `vim.version` buys nothing and `vim.version.cmp` raises on input it cannot
  parse.
- **Unparseable** — a failed write or two nvim processes interleaving. Report
  it and overwrite. Treating it as first run would silently swallow the next
  upgrade, which is the one thing this detector exists to catch.

Two nvim processes are the normal case and `AgentInstance._instances` is
per-process, so both read-modify-write the same file. Write via temp plus
`os.rename` so an interleaving truncates nothing; the unparseable branch is the
backstop if it does.

A `Config` option silences the notice, alongside every other user-visible
behaviour. claude-agent-acp ships patch releases often, and a maintainer signal
that cannot be turned off is a user-facing nag.

The notify belongs at `_connect`'s initialize callback, after
`_apply_initialize_result`. That function is a four-assignment recorder and its
name says so.

### Contradiction checks

Two redundant-signal pairs in the claude adapter, each reported where the
signal is resolved:

- `update.kind == "switch_mode"` while `ClaudeUtils.MODE_SWITCH_TOOLS` has no
  row for `ClaudeUtils.tool_name(update)`, in `__handle_tool_call` where that
  lookup already happens (`__apply_tool_identity` after
  `REFACTOR-acp-tool-call-builders.md`). The provider declaring a mode switch is independent
  of the adapter's own table, so a new `switch_mode` tool announces itself
  instead of rendering as a generic block. `kind == "other"` must not trigger
  it: `other` is the provider's catch-all, carrying every MCP tool, so the
  redundancy only exists for the explicit declaration. `tool_name` may be nil
  when a notification carries no `_meta` at all — that is itself drift and
  should report, so the summary must `tostring` it rather than concatenate.
- `_meta.claudeCode.subagent` set while the resolved `message.kind ~=
  "SubAgent"`, reported from both `__build_tool_call_message` and
  `__build_tool_call_update`. The bridge sets that flag from the tool name
  (`Agent` or `Task`) while the adapter mints the kind from
  `rawInput.subagent_type` — genuinely independent origins.

The subagent check needs a gate, and non-empty `rawInput` is not enough.
`streamedInputRefinement` emits updates built from input truncated at the last
top-level comma, so `rawInput` arrives as `{ description = … }` with
`subagent_type` not yet present — observed in the debug log on ordinary `Agent`
calls, three times with `description` alone against three times with both.
`__apply_raw_input` correctly declines to mint the kind there, so a
`rawInput`-only gate would report on the happy path of essentially every
subagent invocation.

Gate additionally on `update.content ~= nil`. `streamedInputRefinement`'s own
docstring states it never carries `content`, and `__apply_edit_diff` already
depends on that invariant. The initial `tool_call` and the consolidated refine
both carry the key; the streamed refinements do not. That admits exactly the
consolidated refine, the permission-flow `tool_call`, and `session/load` replay.

There is deliberately no check on `_meta.claudeCode.skill`. Now that dispatch
resolves `Skill` from `_meta.claudeCode.toolName`, both signals come out of the
bridge's `claudeCodeMetaFromToolUse` keyed on the same `toolUse.name`, so they
cannot disagree unless that one function splits its own outputs.

### Reporting

Both checks go through `ACPClient:__report_unsupported(summary)`, which the
unknown-method dispatch change introduces: a `@protected` method deduping on
`self._reported` per client instance.

Summaries interpolate the tool name and the kind, nothing else. Dedup keys on
the string, so a `toolCallId` or a `description` in it would degrade dedup to
none — and `session/load` replay re-emits every historical tool call as an
initial `tool_call` with full `rawInput`, so a Task-heavy resume against a
broken build would otherwise report once per replayed block.

Folding the existing `KNOWN_ACP_KINDS` notice into the same method changes it
from per-occurrence to once per distinct kind, since the kind is in its
summary. That is the intended behaviour: a second notice for a kind already
reported tells the user nothing.

`agentic.acp.ClaudeCodeMeta` gains a `subagent?` field. `ClaudeUtils.claude_meta`
already carries the `_meta` nil guard both checks need.

## Additions

`claude_agent_acp_adapter.test.lua` defines two local `make_capturing_adapter`
helpers, one capturing `on_tool_call_update` and one `on_tool_call`; both
capture subscriber messages and neither observes a report. Extend the relevant
one to stub `__report_unsupported` on the adapter table alongside
`__with_subscriber`, and assert on collected summaries — no `Logger.notify`
stubbing needed.

- `kind = "switch_mode"` with a `toolName` absent from `MODE_SWITCH_TOOLS`,
  versus `toolName = "ExitPlanMode"` asserting silence.
- `kind = "other"` with an unknown `toolName`, asserting silence. This is the
  common case — every MCP tool — and a false positive here makes every report
  worthless.
- `subagent = true` with `rawInput = { description = … }` and no `content`,
  asserting silence. This is the streamed-refinement shape and the check's
  most likely false positive.
- `subagent = true` with `content` present and a kind other than `SubAgent`,
  asserting one report.
- The same contradiction twice, asserting one report.

For the store: round-trip, absent file, and corrupt file.

## Expected outcome

Upgrading the provider announces itself once, at the first connect after the
upgrade, naming the old and new versions.

Independently, `ExitPlanMode` losing its mapping, a new `switch_mode` tool
appearing, or the subagent branch failing each announce itself on the
notification that hits it. A rename of `EnterPlanMode` or `EnterWorktree` does
not — those arrive as `kind = "other"` and have no redundant partner, so the
version marker is their only signal.

## Non-goals

A hand-maintained version constant in the source. The bump protocol such a
constant needs already exists as prose in `provider-system/SKILL.md` § "ACP
Providers", and the pin it governs in `doc/agentic.txt` § Requirements sat nine
minors behind the installed build until this work surfaced it. A notice whose
only resolution is editing a constant trains the maintainer to edit it without
re-verifying.

A test asserting the adapter's expectations against the provider's shipped
JavaScript. A repo test that fails when a third-party npm package is absent is
not a repo test.

Extending either detector to the five unverified adapters (gemini, codex,
cursor, auggie, vibe). `_meta.claudeCode` is claude-only, and each provider
needs its own redundant-signal pairs identified first. The version marker is
provider-keyed and would work for any of them, but none has a build anyone has
verified against, so a difference would carry no meaning. The shared code path
must still tolerate a provider reporting no `agentInfo` at all.
