# Plan: pinpoint the danger inside `sh -c '<body>'` in the permission highlight

> **Scope.** UI highlight only — the *single-quoted* `-c` body case. The
> evaluation/auto-approve walk already descends into `-c` bodies and gates each
> inner leaf; nothing about safety changes here. This only sharpens which bytes
> the permission prompt washes. A bug in this code can mis-highlight, never
> mis-approve (the tally walk never feeds `should_auto_approve`).

## Problem

When a Bash command is `zsh -c 'rm -rf /'` and the inner is not approved, the
permission prompt washes the **whole** `zsh -c '...'` leaf instead of just
`rm -rf /` inside it. For exec-wrappers (`timeout 5 rm -rf /`) the prompt
already pinpoints `rm -rf /` and leaves `timeout 5` clean — so the asymmetry is
purely the `-c` path.

## Why it's coarse today (root cause)

The highlight ("tally") walk reuses `inner_source`
(`lua/agentic/utils/shell_parse.lua:587`) to find the inner command and an
*origin* `(row, col)` for mapping inner byte-ranges back into the outer command.

- **Exec-wrapper branch** (`shell_parse.lua:609-615`): slices the *original
  src bytes* of the inner node and returns the inner node's `(row, col)` as
  origin. `command_known_safe` translates the inner's unapproved ranges with
  `translate_ranges` and pinpoints them (`permission_rules.lua:1600-1605`).
- **`-c` branch** (`shell_parse.lua:588-599`): returns `body, nil, false`. The
  body comes *quote-stripped* from `args`, so it has historically been treated
  as having no faithful coordinate mapping → **origin nil** → `command_known_safe`
  returns `false` with no sub-ranges (`permission_rules.lua:1606`) → whole-leaf
  highlight.

## Key insight: a single-quoted body *does* have a 1:1 mapping

A single-quoted token parses as a `raw_string` node. `pure_literal_token`
strips it by removing exactly one leading `'` and one trailing `'`
(`shell_parse.lua:221-224`) — **no escape or expansion processing** (POSIX
single quotes can't contain escapes or even an embedded `'`). So:

- The stripped `body` is **byte-identical** to the source between the quotes.
- The content's first byte sits at the raw_string node's `(sr, sc + 1)` —
  i.e. exactly one column past the opening quote on row 0.
- For multi-line single-quoted bodies, later rows start at column 0 in both the
  inner source and the outer src, which is exactly what `translate_ranges`
  (`permission_rules.lua:1485`) already assumes (`sr == 0 and sc + ocol or sc`).

So for `raw_string` bodies, returning origin `{sr, sc + 1}` makes the existing
wrapper machinery pinpoint the inner danger with no other changes.

Everything else stays coarse (origin nil), because the mapping is not 1:1:
- **Double-quoted** body → `string` node (escapes/`\$`, expansions processed).
- **`$'...'`** ANSI-C quoting → escape processing.
- **Concatenation** (`'rm'$x`), or a body that came through the dynamic path.

## Change (one site)

In `inner_source` (`lua/agentic/utils/shell_parse.lua:588-599`), the `-c`
branch. When the body token's node is a `raw_string`, compute and return an
origin; otherwise keep nil.

```lua
if SHELL_C_COMMANDS[cmd_name] then
    for i, arg in ipairs(args) do
        if arg:match("^%-[a-zA-Z]*c$") then
            local body = args[i + 1]
            if body ~= nil and not args_dynamic[i + 1] then
                -- A single-quoted body (`raw_string`) is byte-identical to its
                -- source content with no escape/expansion processing, so its
                -- coordinates map 1:1 — origin is the content start (one column
                -- past the opening quote). Any other quoting (double, $'...',
                -- concatenation) processes the body, so it has no faithful
                -- mapping and stays coarse (nil origin → whole-leaf highlight).
                local body_node = arg_nodes[i + 1]
                -- args/arg_nodes are inserted in lockstep, so body ~= nil
                -- already guarantees body_node is non-nil — no extra guard.
                local origin = nil
                if body_node:type() == "raw_string" then
                    local sr, sc = body_node:range()
                    origin = { sr, sc + 1 }
                end
                return body, origin, false
            end
            return nil, nil, false -- missing or dynamic body
        end
    end
    return nil, nil, false
end
```

No other code changes. Confirmed safe against the two consumers:

- **Decision walk** (`permission_rules.lua:1047`) destructures
  `local inner, _, writes` — it ignores origin. Unaffected.
- **Tally walk** (`command_known_safe`, `permission_rules.lua:1585-1607`)
  already does `if origin then return false, translate_ranges(...) end`. With a
  non-nil origin it now pinpoints; with nil it falls back as before.
- `extract_commands` and any other `inner_source` caller use only the first
  return value; arity is unchanged.

## Tests

Add to the `describe("tally_unapproved", ...)` block in
`lua/agentic/utils/permission_rules.test.lua` (helper `span_text` at
`:2580-2583`, pattern at `:2585-2596`).

1. **Pinpoints the inner of a single-quoted `-c` body.**
   ```lua
   it("returns only the unapproved inner of a single-quoted -c body", function()
       with_perms({ allow = { "Bash(grep *)" }, deny = { "Bash(rm *)" } }, nil, function()
           local cmd = "zsh -c 'rm -rf /'"
           local ranges = PermissionRules.tally_unapproved(cmd)
           assert.equal(1, #ranges)
           assert.equal("rm -rf /", span_text(cmd, ranges[1]))
       end)
   end)
   ```
   (Confirm the bundled defaults don't already approve `rm`; if they might,
   pin `deny = { "Bash(rm *)" }` as above so the assertion is deterministic.)

2. **Coarse fallback for a double-quoted body** (mapping not 1:1 — must still
   highlight the whole leaf, never a wrong slice).
   ```lua
   it("highlights the whole leaf for a double-quoted -c body", function()
       with_perms({ allow = { "Bash(grep *)" }, deny = { "Bash(rm *)" } }, nil, function()
           local cmd = 'zsh -c "rm -rf /"'
           local ranges = PermissionRules.tally_unapproved(cmd)
           assert.equal(1, #ranges)
           assert.equal(cmd, span_text(cmd, ranges[1]))
       end)
   end)
   ```

3. **Multi-line single-quoted body** (required — the only test exercising the
   row offset in `translate_ranges`, where the `sr + orow` arithmetic lives;
   tests 1–2 are single-row). `"zsh -c 'grep foo\nrm bar'"` highlights only
   `rm bar` on row 1. `span_text` is single-line only, so assert the row
   (`ranges[1][1] == 1`) and extract the text from that row directly.

Also **delete** the now-stale tally test `permission_rules.test.lua`
"highlights the whole leaf for an unsafe -c body (coarse)" (`sh -c 'rm x'`):
its body is single-quoted, so it now pinpoints rather than washing the leaf.
Test 2 (double-quoted) is the replacement coarse-fallback assertion.

The existing decision-walk test `shell_parse.test.lua:82`
(`extract_commands("zsh -c 'rm -f y'")`) must still pass unchanged.

## Docstring updates

- `inner_source` docstring (`shell_parse.lua:570-575`): the line "origin is nil
  because its quote-stripped coordinates cannot be mapped back to `src`" is now
  only true for non-`raw_string` bodies. Reword: single-quoted (`raw_string`)
  bodies map 1:1 and get an origin; other quoting stays nil.
- `command_known_safe` docstring (`permission_rules.lua:1532-1538`): the "`-c`
  body has no faithful coordinate mapping ... stays coarse" sentence now applies
  only to non-single-quoted bodies.
- Inline comment at the recursion site (`permission_rules.lua:1583-1584`): "the
  `-c` body stays coarse" now applies only to non-single-quoted bodies.
- `permissions` skill: no `-c` whole-leaf highlight note exists, so nothing to
  narrow there — skip.

## Validation

```bash
make validate
make test-file FILE=lua/agentic/utils/permission_rules.test.lua
make test-file FILE=lua/agentic/utils/shell_parse.test.lua
```

## Deliberately out of scope

Escape-aware coordinate remapping for double-quoted / `$'...'` bodies. Those
need a per-byte source→content map across escape boundaries; not worth it until
a real danger inside a double-quoted `-c` body shows up in practice. They keep
the correct (coarse) whole-leaf highlight in the meantime.
