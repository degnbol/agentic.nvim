# Plan: Name skeptic and subagent transcripts under their chat, by kind
Status: reviewed spec
Priority: P2
Depends:

## Relevant files
- `lua/agentic/utils/buffer_names.lua` — `Parts`, `format`, `parse`, `is_part`
- `lua/agentic/ui/chat_widget.lua` — `ChatWidget:buffer_name`
- `lua/agentic/background_session.lua` — `_open_transcript`, `Opts`
- `lua/agentic/skeptic/init.lua` — `Skeptic:_start`
- `lua/agentic/session_resume.lua` — `SessionResume.open_name`
- `lua/agentic/subagents.lua` — callers of `buffer_name` (no change)
- `doc/agentic.txt` — `*agentic-buffer-names*`
- `lua/agentic/session_manager.lua` — `buf_of`, `open_buf` (no change:
  their `sub_id` is always a subagent's key)
- Tests: `buffer_names.test.lua`, `chat_widget.test.lua`,
  `background_session.test.lua`, `session_resume.test.lua`,
  `tests/integration/test_open_names.lua`, `test_chat_id.lua`,
  `test_native_subagents.lua`, and any other hit of
  `rg -l 'agentic://|short_key' lua tests`
- Skills: `implement`, `subagents`, `writing`

## Background
A skeptic's transcript is named `agentic://<background key>/background`.
That puts it outside the chat that owns it, and `background` says nothing
the name needs. A subagent's transcript is `agentic://<cid>/<agent key>`,
which does not say what it is. `:ls` of one chat:

```
  2 %a-  "agentic://05f47872"
 20  h-  "agentic://f107b7cf/background"
 67  h-  "agentic://05f47872/c797e3ca"
```

New names put a kind segment before the short key:

```
agentic://<cid>/subagent/<agent key>
agentic://<cid>/subagent/<agent key>/input
agentic://<cid>/skeptic/<skeptic key>
```

## Changes
`lua/agentic/utils/buffer_names.lua`:
- New `--- @alias agentic.BufferNames.Kind "subagent"|"skeptic"`, used by
  every field and param below.
- `Parts`: new field `kind? agentic.BufferNames.Kind`, required when
  `sub_id` is set. `key` is always the chat id. `part` loses `background`.
- `format`: `<key>[/<kind>/<sub_id>][/<part>]`. No default for `kind`.
- `parse`: one segment → chat; two → panel (`is_part`); three
  `<key>/<kind>/<sub_id>` with a known kind → transcript; four
  `<key>/subagent/<sub_id>/input` → message input. Anything else → nil.
  `is_part` no longer accepts `background`; a kind segment is never a part.
- Module docstring: the new shape.

`lua/agentic/ui/chat_widget.lua`:
- `ChatWidget:buffer_name(sub_id, part, kind)`,
  `@param kind? agentic.BufferNames.Kind`, default `"subagent"` when
  `sub_id` is given. Docstring: `part` `input` only with `subagent`.
  Subagent callers stay as they are.

`lua/agentic/background_session.lua`:
- `Opts`: new field `kind agentic.BufferNames.Kind`, the name segment of
  its transcript.
- `_open_transcript`: name it
  `self._opts.widget:buffer_name(self._session_id, nil, self._opts.kind)`.
  Drop the `BufferNames` require if nothing else uses it.

`lua/agentic/skeptic/init.lua`, `Skeptic:_start`: pass `kind = "skeptic"`.

`lua/agentic/session_resume.lua`, `open_name`: replace the
`parts.part == "background"` return with a `parts.kind == "skeptic"`
return (same behaviour: the transcript's own `BufReadCmd` refills it).
Docstring: "a skeptic transcript".

`doc/agentic.txt`, `*agentic-buffer-names*`: the table rows for subagent
transcript, message input and skeptic transcript, and the sentence that
defines `<background key>`, which becomes `<skeptic key>`.

Tests: update the name strings (`test_open_names.lua`'s closed-chat
transcript test needs `<cid>/subagent/<key>`, else it passes on a nil
parse); in `buffer_names.test.lua` replace the `background` cases and
cover format/parse round trips of each shape, and nil for
`<key>/skeptic/<sub>/input`, `<key>/other/<sub>` and the old
`<key>/<sub>` form.

## Expected outcome
`:ls` lists a chat's skeptic and subagent transcripts under the chat's id,
each named by its kind. `:e`, `gf` and `CTRL-W f` on a subagent name work as
before.

## Non-goals
- Renaming transcripts when the chat id changes (`rename_buffers` renames
  panels only). Subagent transcripts already keep the old id then; skeptic
  transcripts now do too, while `Skeptic:_on_session_changed` keeps them
  (a continued session).
- A name quoted in message text keeps the old form and no longer parses.
  Subagent block arguments are rewritten on restore
  (`Subagents:add_history_transcripts`).
