# Bug: a long code line inside a streamed prose fence is hard-wrapped into two

Found reviewing the fence-balancing work. Line numbers are against `3f548f7`.

## Symptom

Code the model streams inside a ` ```lang ` fence is broken mid-statement, and
stays broken — copying it out of the chat yields non-runnable code:

````
```lua
local result = compute(alpha, beta,
gamma, delta, epsilon)
```
````

Reproduced through the real writer at a wrap width of 40, streaming
`` "Here:\n\n```lua\n" ``, then `local result = compute(alpha, beta, gamma,`,
then `" delta, epsilon)\n"`, then the closing fence.

## Mechanism

`MessageWriter:write_message_chunk` (`:973-995`) wraps the last buffer line
immediately when it overflows, so the user sees wrapping during streaming
rather than after the line completes. It has no notion of fences:

```lua
local wrap_width = self:_get_wrap_width()
local end_line = vim.api.nvim_buf_line_count(bufnr) - 1
local tail = ...
if wrap_width > 0 and #tail > wrap_width then
    local wrapped = TextWrap.wrap_single_line(tail, wrap_width)
```

`wrap_single_line_with_offsets` (`text_wrap.lua:336-348`) skips fence
*delimiter* lines (`^%s*```) but nothing tells it that a line is fence
*content*. The two sites that do track fence state are no help here:

- `wrap_prose` tracks `in_fence`, but only within the region it is handed, and
  it runs on the *reflow* path — after the damage.
- `TextWrap.unclosed_fence` knows the parser's rule but is only consulted at
  prose-run ends and by the reflow marker clamp.

**The break is permanent.** Nothing rejoins lines: the later
`_reflow_chunks` pass sees the fence open and passes both halves through
untouched.

## Trigger conditions

The line must cross the wrap width at a chunk boundary *before* its newline
arrives. A chunk that carries both the overflow and the trailing `\n` splits
into `lines_to_write`, leaving a short last line, and the wrap does not fire —
which is why the same code block survives when the provider happens to break
tokens differently. Any code line longer than the wrap width will hit it for
some token split.

Only prose fences are affected. Tool-call command and body fences are built by
`prepare_block_lines` and never go through the streaming tail wrap.

## Fix sketch

Gate the tail wrap on fence state. The state is already computable from the
reflow region: `TextWrap.unclosed_fence` over `_chunk_start_line ..` the tail,
which after the marker clamp is guaranteed to start outside a fence — so a
non-nil result means the tail is inside a fence and must be left alone.

Cheaper alternative if that scan proves too hot per chunk: track the open fence
on the writer as chunks land, resetting it wherever `_chunk_start_line` resets.
That adds another piece of cross-turn state (see the `session-lifecycle` skill
for the flag hazards), so prefer the scan unless it measures badly.

Whichever is chosen, the docstring on `_reflow_chunks` claims the marker clamp
keeps `wrap_prose` from hard-wrapping code as prose. That is true of the reflow
path only; the tail wrap defeats it independently. Keep the two claims distinct.

## Not to be confused with

- `48820e8` "never hard-wrap inside inline code spans" — that protects a
  backtick span *within* one line, and does not look at fenced blocks.
- `notes/bug-unclosed-prose-fence-runaway-fold.md` — an unbalanced fence
  running the parse away. Different defect; this one needs the fence to be
  perfectly well-formed.
