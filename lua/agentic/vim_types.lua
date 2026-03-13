--- Stub definitions for vim types that lua-language-server's bundled
--- meta files don't export.  This file is never `require()`d at runtime;
--- LuaLS picks it up as part of the workspace and uses the annotations
--- for type checking only.

--- @class vim.Diagnostic
--- @field bufnr integer
--- @field lnum integer 0-indexed line number
--- @field end_lnum integer
--- @field col integer 0-indexed column
--- @field end_col integer
--- @field severity integer
--- @field message string
--- @field source? string
--- @field code? string|integer
--- @field namespace? integer
--- @field user_data? any

--- @alias vim.diagnostic.Severity
--- | 1 # Error
--- | 2 # Warn
--- | 3 # Info
--- | 4 # Hint

--- @class vim.diagnostic.GetOpts
--- @field namespace? integer
--- @field lnum? integer
--- @field severity? vim.diagnostic.Severity|vim.diagnostic.Severity[]

--- @alias vim.NIL userdata

--- @alias vim.log.levels integer

--- @class TSNode

--- @alias vim.keymap.set.Opts vim.keymap.set.Opts.Base

--- @class vim.keymap.set.Opts.Base
--- @field buffer? integer|boolean
--- @field silent? boolean
--- @field noremap? boolean
--- @field nowait? boolean
--- @field expr? boolean
--- @field desc? string
--- @field remap? boolean
--- @field replace_keycodes? boolean

--- @class vim.api.keyset.win_config
--- @field relative? string
--- @field win? integer
--- @field anchor? string
--- @field width? integer
--- @field height? integer
--- @field bufpos? integer[]
--- @field row? integer
--- @field col? integer
--- @field focusable? boolean
--- @field external? boolean
--- @field zindex? integer
--- @field style? string
--- @field border? string|string[]
--- @field title? string|table
--- @field title_pos? string
--- @field footer? string|table
--- @field footer_pos? string
--- @field noautocmd? boolean
--- @field fixed? boolean
--- @field hide? boolean
--- @field vertical? boolean
--- @field split? string
