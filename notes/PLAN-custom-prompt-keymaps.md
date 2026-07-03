# PLAN: user-configurable canned-prompt keymaps

Status: **implemented**

Placement note: shipped as top-level `keymaps.prompts`, not nested under
`keymaps.widget`. `keymaps.widget` is typed `table<string, KeymapValue>` (a
homogeneous action-binding map); a nested prompt-text map is not a KeymapValue
and would break that type. The `Keymaps` class already carries distinct
`@field`s, so `prompts` slots in as one more. All other design decisions below
shipped as written; substitute `keymaps.prompts` wherever the body says
`keymaps.widget.prompts`.

## Goal

Let a user bind a key inside the widget to send a fixed prompt string, in one
line of config. Motivating case: a `<localleader>y` → `"Go ahead."` approval
shortcut — one more entry alongside the built-in "Continue".

## Key observation

`keymaps.widget.continue` (`config_default.lua:219`, `<localLeader>c`) is already
a canned-prompt keymap: its bind block hard-codes `send_prompt("Continue")`
(`chat_widget.lua:760-767`) on every widget buffer. That "Continue" string was
only ever meant to be the *default* of a configurable prompt-keymap. So this
feature is not new machinery — it is generalising `continue` into a map of
`key → prompt` entries, of which "Continue" is the shipped default, and letting
the user append more.

Because the config deep-merges keymaps by key
(`Object.merge_config` → `vim.tbl_deep_extend("force", …)`, `object.lua:32`), a
user who adds `<localleader>y` keeps the default `<localleader>c` — literally
"one more entry".

## Design

Replace the bespoke `continue` action with a `key → prompt` map applied to all
widget buffers. It lives under `keymaps.widget` (not a new top-level section):
its scope — "every widget buffer, session-scoped" — is exactly what
`keymaps.widget` already means.

`config_default.lua`:

```lua
keymaps = {
    widget = {
        ...
        --- Send a fixed prompt to this widget's session. key → prompt text
        --- (or { prompt, mode?, desc? }). Set a key to vim.NIL or "" to
        --- disable an inherited entry. Plain `nil` does NOT disable — a nil
        --- value is absent from the Lua table, so the merge keeps the default.
        prompts = {
            ["<localLeader>c"] = "Continue",
        },
    },
    ...
}
```

User config — merges by key, so this *adds* to the defaults:

```lua
require("agentic").setup {
    keymaps = {
        widget = {
            prompts = {
                ["<localLeader>y"] = "Go ahead.",
            },
        },
    },
}
```

A value may also be a table when mode/desc control is wanted:

```lua
["<localLeader>y"] = { prompt = "Go ahead.", mode = { "n", "v" }, desc = "Agent: yes" },
```

`mode` defaults to `"n"`; `desc` defaults to
`"Prompt: " .. prompt` (newlines collapsed, capped at 40 chars).

### Disabling an inherited entry

`vim.NIL` (a real userdata sentinel) survives the deep merge as a distinct
value the bind loop skips; `""` also disables since an empty prompt is
meaningless to send. Plain `nil` does **not** work — a nil table value simply
isn't present in `user_keys`, so `tbl_deep_extend` keeps the default:

```lua
require("agentic").setup {
    keymaps = {
        widget = {
            prompts = {
                ["<localLeader>c"] = vim.NIL,   -- drop the built-in "Continue"
                ["<localLeader>y"] = "Go ahead.",
            },
        },
    },
}
```

Verified: `vim.tbl_deep_extend("force", {a="Continue", b="x"}, {a=vim.NIL})`
yields `a == vim.NIL`, `b == "x"`.

### Why a function (`map_prompt`) was rejected

To match `continue`'s semantics a binding must be buffer-local to widget buffers
and session-scoped. A `map_prompt()` doing a bare `vim.keymap.set` would be
global — reintroducing the leak + auto-spawn bug (`send_prompt` →
`get_session_for_tab_page(nil, …)` spawns a session, `session_registry.lua:20-31`).
To be correct it would have to push into the same per-widget bind list the config
already drives, making the config the real primitive and the function redundant
sugar. The config map is the mechanism; there is no second API.

## Implementation

1. `config_default.lua`: remove `keymaps.widget.continue`; add
   `keymaps.widget.prompts = { ["<localLeader>c"] = "Continue" }`.
2. Type annotations for `keymaps.widget`: drop `continue`; add
   `prompts: table<string, string | { prompt: string, mode?: string|string[], desc?: string }>`.
3. `chat_widget.lua`: delete the `continue` bind block (L760-767). In the same
   `for _, bufnr in pairs(self.buf_nrs)` loop, iterate `Config.keymaps.widget.prompts`:

   ```lua
   for lhs, spec in pairs(Config.keymaps.widget.prompts) do
       local prompt
       if type(spec) == "string" then
           prompt = spec
       elseif type(spec) == "table" then
           prompt = spec.prompt
       end
       -- vim.NIL, nil, "" all fall through to skip:
       if prompt and prompt ~= "" then
           local km = (type(spec) == "table" and spec.mode)
               and { { lhs, mode = spec.mode } } or lhs
           local desc = (type(spec) == "table" and spec.desc)
               or ("Prompt: " .. prompt:gsub("%s+", " "):sub(1, 40))
           BufHelpers.multi_keymap_set(km, bufnr, function()
               self.on_submit_input(prompt)
           end, { desc = desc })
       end
   end
   ```

   Notes on the shape:
   - `is_keymap_disabled` is **not** reused here — it reports `#{prompt=…} == 0`
     as disabled, which would silently drop every table-form entry. The
     `prompt and prompt ~= ""` guard is the correct disable test.
   - The lhs lives in the config *key*, but `multi_keymap_set` reads the lhs
     from `key[1]` and the mode from `key.mode`, so the table form is
     reconstructed as `{ { lhs, mode = spec.mode } }`.
   - `vim.NIL` cannot be indexed (`spec.prompt` on userdata errors), so the
     `type(spec)` checks must precede any field access — they do.
4. Callback sends to **this widget's** session via `self.on_submit_input(prompt)`
   (= `session:_handle_input_submit`, `session_manager.lua:240`), not through
   `send_prompt`. `send_prompt` additionally calls
   `session.widget:show({focus_prompt=false})`, which is dead code here: a
   buffer-local map only fires when its buffer is in a focused window, so the
   widget is already visible. Using `self` also avoids `send_prompt`'s
   `get_session_for_tab_page(nil, …)` auto-spawn branch entirely.

## Verification

- Unit: merging `keymaps.widget.prompts = { ["x"] = "hi" }` yields both `x` and
  the default `<localLeader>c` on config (proves append-not-replace).
- Unit: merging `keymaps.widget.prompts = { ["<localLeader>c"] = vim.NIL }`
  leaves `<localLeader>c == vim.NIL`, so the bind loop skips it (proves disable
  survives the merge).
- Live: with `<localleader>y` set, open a session, press it in the chat/input
  buffer → prompt sent; press it in an ordinary buffer → nothing (no map, no
  session spawned). `<localleader>c` still sends "Continue".

## Downstream (personal config) after this lands

`lua/plugins/agents.lua` drops the interim `FileType` autocmd and adds one line
under `setup`'s `keymaps.widget.prompts`: `["<localLeader>y"] = "Go ahead."`.
