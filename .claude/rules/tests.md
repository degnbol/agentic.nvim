---
paths: "**/*.test.lua,tests/**"
---

# Tests

**Framework:** [mini.test](https://github.com/nvim-mini/mini.test) with
`emulate_busted = true`. `make test` (also `test-verbose`, `test-file FILE=…`).
mini.nvim clones into `deps/` on first run.

Tests are **co-located** with sources: `<module>.test.lua` next to `<module>.lua`.

**Always read these before writing tests** — they document the actual API
surface, including LuaCATS types:

- `tests/helpers/assert.lua` — custom luassert-style API wrapping
  `MiniTest.expect`.
- `tests/helpers/spy.lua` — spy/stub helpers (mini.test ships no equivalent).
- `tests/helpers/child.lua` — child-neovim wrapper.

## Spy/stub API differences from luassert

- No `spy.call(n)` method. Read `spy.calls[n]` directly — each entry is
  `{ arg1, ..., n = arg_count }`.
- Methods called with `:` syntax include `self` as the first arg in `.calls[i]`.
- `called_with` uses `vim.deep_equal` and cannot match function arguments
  (callbacks). Inspect `.calls[i]` manually.
- `returns` and `invokes` are mutually exclusive on the same stub — last one
  wins.
- `reset` clears `.calls`/`.call_count` only, **not** behaviour (`returns`
  / `invokes`).
- Always call `revert` in `after_each`. Failing to revert poisons sibling
  tests in the same file.

## Test isolation: per-file, not per-test

Each test FILE runs in its own neovim process. Cross-file pollution is
impossible. Within a file, tests share the same neovim — `require()` cache,
globals, autocmds, and `vim.schedule` queues carry over. `vim.wait` in a
helper can let mini.test re-enter sibling cases mid-test.

The whole current suite passes under file-level isolation. Only escalate to
**per-test child neovim** when a `vim.wait` helper actually causes
re-entrancy bleed:

```lua
local Child = require("tests.helpers.child")
describe("X", function()
    local child = Child:new()
    before_each(child.setup)
    after_each(child.stop)
end)
```

~50ms per test overhead. See `tests/integration/*` for working examples.

## `package.loaded` nilling

If a test nils a shared module (`package.loaded["agentic.config"] = nil`)
and re-requires it, sibling test files that captured the module at
file-load time hold a stale reference. Save+restore:

```lua
local original = {}
local mods = { "agentic.config", "agentic.other" }
before_each(function()
    for _, m in ipairs(mods) do
        original[m] = package.loaded[m]; package.loaded[m] = nil
    end
end)
after_each(function()
    for _, m in ipairs(mods) do package.loaded[m] = original[m] end
end)
```

## Multi-tabpage tests

The plugin keeps one session instance per tabpage. Any test that touches
session/widget/registry state must verify cross-tabpage isolation and
cleanup on tabpage close — open `tabnew`, instantiate, assert independence,
close, assert no leaks.

## Integration tests: mock transport

Anything that exercises an ACP code path must stub `agentic.acp.transport`
before the code under test starts a session, otherwise a real provider
subprocess spawns and API tokens may end up in test output.

## Child process gotchas

- `child.lua_get([[expr]])` auto-prepends `return` — single expression only.
  Multi-line code goes through `child.lua([[…]])`.
- `vim.wait()` errors with E5560 inside `child.lua(...)`. Use `vim.uv.sleep`
  in the **parent** test instead — the child continues independently.
- Functions and userdata can't cross the RPC boundary. Compute inside the
  child and return a serialisable result.
