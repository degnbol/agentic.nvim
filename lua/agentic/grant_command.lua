local Config = require("agentic.config")
local Glyphs = require("agentic.glyphs")
local GrantSafety = require("agentic.utils.grant_safety")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

--- The /grant command: adds, lists and removes the session's grant scopes.
--- @class agentic.GrantCommand
--- @field _permission_manager agentic.ui.PermissionManager
--- @field _message_writer agentic.ui.MessageWriter
--- @field _get_cwd fun(): string
--- @field _is_mid_turn fun(): boolean
local GrantCommand = {}
GrantCommand.__index = GrantCommand

--- @param permission_manager agentic.ui.PermissionManager Holds the grant scopes
--- @param message_writer agentic.ui.MessageWriter Chat the notices go to
--- @param get_cwd fun(): string Session cwd; `.`, `root` and relative arguments resolve against it
--- @param is_mid_turn fun(): boolean The `mid_turn` of a notice written now
--- @return agentic.GrantCommand
function GrantCommand:new(
    permission_manager,
    message_writer,
    get_cwd,
    is_mid_turn
)
    return setmetatable({
        _permission_manager = permission_manager,
        _message_writer = message_writer,
        _get_cwd = get_cwd,
        _is_mid_turn = is_mid_turn,
    }, self)
end

--- Resolve a `/grant` argument to an absolute path or glob. `root` is the git
--- root of `cwd`. Anything else (`.` included) has `~` and env vars expanded
--- and, when relative, resolves against `cwd`. An unset env var stays
--- literal.
--- @param input string
--- @param cwd string
--- @return string|nil pattern
--- @return string|nil err Why `input` does not resolve
function GrantCommand.resolve_input(input, cwd)
    if input == "root" then
        local root = vim.fs.root(cwd, ".git")
        if not root then
            return nil, "no git root"
        end
        return root, nil
    end
    local expanded = vim.fs.normalize(input)
    if expanded:sub(1, 1) ~= "/" then
        expanded = vim.fs.normalize(vim.fs.joinpath(cwd, expanded))
    end
    return expanded, nil
end

--- Write a `/grant` chat notice.
--- @param title string
--- @param off boolean The notice withdraws a grant
function GrantCommand:_notice(title, off)
    self._message_writer:write_notice({
        glyph = Glyphs.COMMAND.grant,
        -- Same glyph as the add notice, struck through — Nerd Fonts has no
        -- struck-through handshake to switch to.
        glyph_hl = off and Theme.HL_GROUPS.GLYPH_OFF or nil,
        title = title,
        mid_turn = self._is_mid_turn(),
    })
end

--- Add a grant scope for the `/grant` argument `input`. A root that does not
--- exist yet is still granted, with a warning. Unless `quiet`, also reports
--- an argument that does not resolve, confirms in the chat, and warns about a
--- wide scope.
--- @param input string
--- @param quiet boolean
function GrantCommand:_add(input, quiet)
    local pattern, err = GrantCommand.resolve_input(input, self._get_cwd())
    if not pattern then
        if not quiet then
            self._message_writer:write_error_action(
                string.format("/grant %s: %s", input, err)
            )
        end
        return
    end

    local scope = GrantSafety.compile_scope(pattern, input)
    local added = self._permission_manager:add_grant_scope(scope)

    if not vim.uv.fs_stat(scope.root) then
        Logger.notify(
            string.format("/grant: %s does not exist yet", scope.root),
            vim.log.levels.WARN,
            { title = "Agentic /grant" }
        )
    end

    if quiet then
        return
    end
    if not added then
        self:_notice("already granted: " .. scope.display, false)
        return
    end
    self:_notice(scope.display, false)
    local wide, reason =
        GrantSafety.is_wide_scope(scope, GrantSafety.tmp_roots())
    if wide then
        Logger.notify(
            string.format(
                "Wide grant (%s): %s — auto-approves edit/write/create/delete/move",
                reason or "wide",
                scope.display
            ),
            vim.log.levels.WARN,
            { title = "Agentic /grant" }
        )
    end
end

--- Grant every `Config.permissions.default_grant` entry. An entry naming an
--- unset env var (`$TMPDIR` on most Linux systems) is skipped.
function GrantCommand:apply_defaults()
    for _, entry in ipairs(Config.permissions.default_grant) do
        if not vim.fs.normalize(entry):find("%$[%w_]") then
            self:_add(entry, true)
        end
    end
end

--- Remove every grant scope.
function GrantCommand:_clear()
    self._permission_manager:clear_grant_scopes()
    self:_notice("grant cleared", true)
end

--- Open the /grant selector menu: `.`, `root` and every active scope as
--- toggles (active ones marked `✓`), a path or glob prompt, and Off.
--- @param on_done fun()|nil Called once the grant question is settled, cancelling
---   included. Runs after this returns: the dialogs outlive the call.
function GrantCommand:_show_picker(on_done)
    on_done = on_done or function() end
    local cwd = self._get_cwd()

    --- @type table<string, agentic.utils.GrantSafety.Scope>
    local active = {}
    for _, scope in ipairs(self._permission_manager:get_grant_scopes()) do
        active[scope.key] = scope
    end

    --- @type { kind: "toggle"|"path"|"off", label: string, input?: string, key?: string }[]
    local items = {}
    --- @type table<string, boolean>
    local listed = {}
    --- @param input string
    --- @param key string|nil Scope key `input` resolves to; nil skips it
    local function add_toggle(input, key)
        if not key or listed[key] then
            return
        end
        listed[key] = true
        local label = input
        if input == "." or input == "root" then
            label =
                string.format("%s (%s)", input, vim.fn.fnamemodify(key, ":~"))
        end
        table.insert(items, {
            kind = "toggle",
            label = (active[key] and "✓ " or "") .. label,
            input = input,
            key = key,
        })
    end
    add_toggle(".", (GrantCommand.resolve_input(".", cwd)))
    add_toggle("root", (GrantCommand.resolve_input("root", cwd)))
    for _, scope in ipairs(self._permission_manager:get_grant_scopes()) do
        add_toggle(scope.display, scope.key)
    end
    table.insert(items, { kind = "path", label = "Path or glob…" })
    table.insert(items, { kind = "off", label = "Off" })

    vim.ui.select(items, {
        prompt = "Agentic grant:",
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if not choice then
            on_done()
        elseif choice.kind == "off" then
            self:_clear()
            on_done()
        elseif choice.kind == "path" then
            vim.ui.input({ prompt = "Path or glob: " }, function(input)
                if input and vim.trim(input) ~= "" then
                    self:run(vim.trim(input), on_done)
                else
                    on_done()
                end
            end)
        elseif active[choice.key] then
            self._permission_manager:remove_grant_scope(choice.key)
            self:_notice("grant removed: " .. active[choice.key].display, true)
            on_done()
        else
            self:_add(choice.input, false)
            on_done()
        end
    end)
end

--- Dispatch /grant: an empty arg opens the picker, `off` clears every grant,
--- anything else is added as a path or glob.
--- @param arg string Trimmed argument
--- @param on_done fun()|nil Called once the grant question is settled. With an
---   empty `arg` that is after this returns, when the picker closes.
function GrantCommand:run(arg, on_done)
    on_done = on_done or function() end

    if arg == "" then
        self:_show_picker(on_done)
        return
    end

    if arg == "off" then
        self:_clear()
    else
        self:_add(arg, false)
    end
    on_done()
end

return GrantCommand
