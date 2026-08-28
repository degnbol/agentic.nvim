local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local DiffJump = require("agentic.ui.diff_jump")
local FileSystem = require("agentic.utils.file_system")
local GitFiles = require("agentic.utils.git_files")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

--- Extmarks are buffer-scoped, so a module-level namespace is fine even though
--- one FileActivity exists per tabpage (see `.claude/rules/multi-tabpage.md`).
local NS_ACTIVITY = vim.api.nvim_create_namespace("agentic_file_activity")

--- @alias agentic.ui.FileActivity.OpClass "create"|"edit"|"delete"|"read"

--- Reads sort below every mutation; create, edit and delete share a tier so
--- that a path's op class stays a column of its single row rather than
--- deciding which section the row lives in.
local OP_RANK = { create = 1, edit = 1, delete = 1, read = 2 }

local OP_MARKER = { create = "+", edit = "~", delete = "-", read = "·" }

local OP_HL = {
    create = Theme.HL_GROUPS.ACTIVITY_CREATE,
    edit = Theme.HL_GROUPS.ACTIVITY_EDIT,
    delete = Theme.HL_GROUPS.ACTIVITY_DELETE,
    read = Theme.HL_GROUPS.ACTIVITY_READ,
}

local PLACEHOLDER = "No files changed yet"

--- Marks a row whose newest op the user has not seen. Drawn in the sign column,
--- immediately left of the op marker: a fixed-width gutter cannot shift the row
--- text depending on whether the mark is there, which padded buffer text or
--- inline virtual text both would.
local UNSEEN_MARKER = "●"

--- A single recorded file operation. Append-only: reversion, counts and the
--- unseen marker are all derived, so nothing mutates an op after it lands.
--- @class agentic.ui.FileActivity.Op
--- @field seq integer Monotonic within the session; ordering and unseen-ness key on it
--- @field tool_call_id string Idempotency key, and provenance for locating the call in the chat
--- @field path string Absolute and canonicalised (see FileSystem.canonical_path)
--- @field op agentic.ui.FileActivity.OpClass
--- @field dest_path? string Destination of a move; no surveyed provider reports one
--- @field ranges? agentic.ui.MessageWriter.HunkRange[] Changed line ranges, when the provider reported them

--- One path's ops collapsed for display.
--- @class agentic.ui.FileActivity.Row
--- @field path string
--- @field op agentic.ui.FileActivity.OpClass Class of the newest op on this path
--- @field seq integer Highest seq across this path's ops
--- @field ranges agentic.ui.MessageWriter.HunkRange[] Union of every op's ranges, in record order

--- Persisted form. `last_viewed_seq` travels with the ops so the unseen marker
--- survives a resume, which is the killed-and-came-back case the panel is for.
--- @class agentic.ui.FileActivity.Data
--- @field ops agentic.ui.FileActivity.Op[]
--- @field last_viewed_seq integer

--- Session-wide tally of the files the agent has changed, rendered as one row
--- per path in a manually toggled panel.
--- @class agentic.ui.FileActivity
--- @field _ops agentic.ui.FileActivity.Op[] Append-only, ascending in seq
--- @field _recorded table<string, boolean> tool_call_ids already appended
--- @field _next_seq integer
--- @field _last_viewed_seq integer Highest seq the user has seen; bumped when the panel closes
--- @field _reverted table<string, boolean> Paths the last reconcile found back at their HEAD content
--- @field _bufnr integer The ChatWidget's activity buffer
--- @field _on_change fun(activity: agentic.ui.FileActivity)
local FileActivity = {}
FileActivity.__index = FileActivity

--- @param bufnr integer The activity buffer number from ChatWidget
--- @param on_change fun(activity: agentic.ui.FileActivity) Called after every render (e.g. to refresh the chat header count)
--- @return agentic.ui.FileActivity
function FileActivity:new(bufnr, on_change)
    local instance = setmetatable({
        _ops = {},
        _recorded = {},
        _next_seq = 1,
        _last_viewed_seq = 0,
        _reverted = {},
        _bufnr = bufnr,
        _on_change = on_change,
    }, self)

    instance:_setup_keybindings()
    instance:render()

    return instance
end

--- Directories whose contents are scratch rather than project work.
---
--- Resolved through `canonical_path` because `/tmp` and `$TMPDIR` are symlinks
--- on macOS while recorded paths are canonicalised. Computed once per process:
--- these are environment, not per-tabpage state.
--- @type string[]|nil
local scratch_cache = nil

--- @return string[]
local function scratch_roots()
    if not scratch_cache then
        scratch_cache = { FileSystem.canonical_path("/tmp") }
        local tmpdir = vim.uv.os_getenv("TMPDIR")
        if tmpdir and tmpdir ~= "" then
            table.insert(scratch_cache, FileSystem.canonical_path(tmpdir))
        end
    end
    return scratch_cache
end

--- @param path string
--- @param prefix string
--- @return boolean
local function is_under(path, prefix)
    return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

--- Sort tier of a path's location: project work, then anything else, then
--- scratch. Keeps the rows the user is reviewing above the incidental ones.
--- @param path string
--- @param project_root string|nil
--- @param scratch string[]
--- @return integer
local function location_rank(path, project_root, scratch)
    if project_root and is_under(path, project_root) then
        return 1
    end
    for _, root in ipairs(scratch) do
        if is_under(path, root) then
            return 3
        end
    end
    return 2
end

--- Record a file operation. Idempotent in `op.tool_call_id`: a provider may
--- repeat a completion (hook retry cycles), and `session/load` replays every
--- tool call into the same handlers on top of a restored log.
--- @param op { tool_call_id: string, path: string, op: agentic.ui.FileActivity.OpClass, dest_path?: string, ranges?: agentic.ui.MessageWriter.HunkRange[] }
--- @return boolean recorded False when this tool call was already in the log
function FileActivity:record(op)
    if self._recorded[op.tool_call_id] then
        return false
    end
    self._recorded[op.tool_call_id] = true

    --- @type agentic.ui.FileActivity.Op
    local entry = {
        seq = self._next_seq,
        tool_call_id = op.tool_call_id,
        path = FileSystem.canonical_path(op.path),
        op = op.op,
        dest_path = op.dest_path,
        ranges = op.ranges,
    }
    self._next_seq = self._next_seq + 1
    table.insert(self._ops, entry)

    self:render()
    return true
end

--- Collapse the op log into one row per path, sorted for display: mutations
--- before reads, project files before scratch, alphabetical within a tier.
---
--- Alphabetical rather than by insertion order: directory grouping emerges and
--- a row can be found by guessing where it is. Insertion order's one advantage
--- — an append never shifts an existing row — only matters while the panel is
--- open, and it is a toggle that is normally closed while the agent works.
--- @param include_reverted boolean Keep paths the last reconcile found unchanged
--- @return agentic.ui.FileActivity.Row[]
function FileActivity:_all_rows(include_reverted)
    --- @type table<string, agentic.ui.FileActivity.Row>
    local by_path = {}

    for _, op in ipairs(self._ops) do
        local row = by_path[op.path]
        if not row then
            row = { path = op.path, op = op.op, seq = op.seq, ranges = {} }
            by_path[op.path] = row
        elseif op.seq > row.seq then
            row.op = op.op
            row.seq = op.seq
        end
        for _, range in ipairs(op.ranges or {}) do
            table.insert(row.ranges, range)
        end
    end

    local project_root = vim.uv.cwd()
    local scratch = scratch_roots()

    --- @type agentic.ui.FileActivity.Row[]
    local rows = {}
    for path, row in pairs(by_path) do
        if include_reverted or not self._reverted[path] then
            table.insert(rows, row)
        end
    end

    -- Paths are unique, so the final tie-break makes this a total order and
    -- the result independent of `pairs` iteration order.
    table.sort(rows, function(a, b)
        local a_op, b_op = OP_RANK[a.op] or 1, OP_RANK[b.op] or 1
        if a_op ~= b_op then
            return a_op < b_op
        end
        local a_loc = location_rank(a.path, project_root, scratch)
        local b_loc = location_rank(b.path, project_root, scratch)
        if a_loc ~= b_loc then
            return a_loc < b_loc
        end
        return a.path < b.path
    end)

    return rows
end

--- The rows as rendered, honouring `windows.activity.hide_reverted`.
--- @return agentic.ui.FileActivity.Row[]
function FileActivity:rows()
    return self:_all_rows(not Config.windows.activity.hide_reverted)
end

--- Number of changed files to advertise ambiently. Reads are excluded: they
--- would swamp the signal by the third turn.
--- @return integer
function FileActivity:count()
    local total = 0
    for _, row in ipairs(self:rows()) do
        if row.op ~= "read" then
            total = total + 1
        end
    end
    return total
end

--- The row rendered on a buffer line, or nil for the placeholder line.
--- @param lnum integer 1-based buffer line
--- @return agentic.ui.FileActivity.Row|nil
function FileActivity:row_at(lnum)
    return self:rows()[lnum]
end

--- Treat every currently recorded op as seen, clearing the unseen markers.
function FileActivity:mark_viewed()
    local highest = 0
    for _, op in ipairs(self._ops) do
        if op.seq > highest then
            highest = op.seq
        end
    end
    if highest == self._last_viewed_seq then
        return
    end
    self._last_viewed_seq = highest
    self:render()
end

--- Re-check whether each recorded change is still on disk, then re-render.
--- Computed on demand rather than at edit time so the cost is paid once per
--- panel open instead of once per tool call, and so a change the user undid —
--- or committed — stops being advertised.
---
--- A path is no longer a change when git does not report it AND either it has
--- vanished or it is tracked, i.e. something else can vouch for its content.
--- That covers an undone edit, a created file deleted again, and a commit of the
--- agent's work. It deliberately leaves an untracked file that still exists,
--- outside a repository or inside one: nothing can say what it should contain,
--- so the row stays rather than being dropped on a guess. A tracked deletion
--- stays too — git reports it, and a deletion is a change.
--- @param callback fun()|nil Invoked after the refreshed rows are rendered
function FileActivity:reconcile(callback)
    --- @type agentic.ui.FileActivity.Row[]
    local mutations = {}
    for _, row in ipairs(self:_all_rows(true)) do
        if row.op ~= "read" then
            table.insert(mutations, row)
        end
    end

    local function finish(reverted)
        self._reverted = reverted
        self:render()
        if callback then
            callback()
        end
    end

    local git_root = vim.fs.root(vim.uv.cwd() or 0, ".git")
    if not git_root then
        --- @type table<string, boolean>
        local reverted = {}
        for _, row in ipairs(mutations) do
            if not vim.uv.fs_stat(row.path) then
                reverted[row.path] = true
            end
        end
        finish(reverted)
        return
    end

    if #mutations == 0 then
        finish({})
        return
    end

    GitFiles.dirty_paths(git_root, function(dirty)
        -- nil means git could not answer; every row keeps its benefit of the
        -- doubt rather than the panel emptying itself.
        if not dirty then
            finish({})
            return
        end

        --- @type table<string, boolean>
        local reverted = {}
        for _, row in ipairs(mutations) do
            if
                not dirty[row.path]
                and (
                    not vim.uv.fs_stat(row.path)
                    or GitFiles.is_tracked(row.path, git_root)
                )
            then
                reverted[row.path] = true
            end
        end
        finish(reverted)
    end)
end

--- Send the rows to the quickfix list, positioned at each file's first
--- recorded hunk. Exported on demand rather than owned: the quickfix list is
--- global, so a panel that kept it in sync would collide across tabpages.
--- @return integer count Entries added
function FileActivity:to_quickfix()
    --- @type vim.quickfix.entry[]
    local items = {}
    for _, row in ipairs(self:rows()) do
        local first = row.ranges[1]
        table.insert(items, {
            filename = row.path,
            lnum = first and first.start_line or 1,
            text = row.op,
        })
    end

    vim.fn.setqflist(
        {},
        " ",
        { title = "Agentic file activity", items = items }
    )
    return #items
end

--- @return agentic.ui.FileActivity.Data
function FileActivity:serialize()
    --- @type agentic.ui.FileActivity.Data
    local data = {
        ops = self._ops,
        last_viewed_seq = self._last_viewed_seq,
    }
    return data
end

--- Adopt a persisted log, keeping any ops already recorded in this instance.
---
--- Both orders happen: on `session/load` the provider's replay can re-enter the
--- tool-call handlers before the stored log has been read off disk. Stored ops
--- keep their original seq so `last_viewed_seq` still means what it did when it
--- was written; ops recorded before the load are re-numbered above them, and
--- dropped when the stored log already has their tool call.
--- @param data agentic.ui.FileActivity.Data|nil
function FileActivity:load(data)
    if not data then
        return
    end

    local recorded_before_load = self._ops
    self._ops = {}
    self._recorded = {}
    self._next_seq = 1

    for _, op in ipairs(data.ops or {}) do
        -- A hand-edited or truncated session file must not put a nil key into
        -- the path index, which would error inside every later render.
        if
            op.tool_call_id
            and op.path
            and not self._recorded[op.tool_call_id]
        then
            self._recorded[op.tool_call_id] = true
            self._next_seq = math.max(self._next_seq, (op.seq or 0) + 1)
            table.insert(self._ops, op)
        end
    end

    for _, op in ipairs(recorded_before_load) do
        if not self._recorded[op.tool_call_id] then
            self._recorded[op.tool_call_id] = true
            op.seq = self._next_seq
            self._next_seq = self._next_seq + 1
            table.insert(self._ops, op)
        end
    end

    self._last_viewed_seq = data.last_viewed_seq or 0
    self:render()
end

--- Drop the whole tally. Only a new conversation warrants this — a cancelled
--- turn, a provider switch or a resumed session all continue the same one.
function FileActivity:clear()
    self._ops = {}
    self._recorded = {}
    self._next_seq = 1
    self._last_viewed_seq = 0
    self._reverted = {}
    self:render()
end

function FileActivity:render()
    local rows = self:rows()

    --- @type string[]
    local lines = {}
    for _, row in ipairs(rows) do
        table.insert(
            lines,
            string.format(
                "%s %s",
                OP_MARKER[row.op] or "~",
                FileSystem.to_smart_path(row.path)
            )
        )
    end

    -- A blank buffer would make the panel look broken while it is open, and
    -- reads as an empty window to any code that sizes on line count.
    if #lines == 0 then
        lines = { PLACEHOLDER }
    end

    local rendered = BufHelpers.with_modifiable(self._bufnr, function(bufnr)
        vim.api.nvim_buf_clear_namespace(bufnr, NS_ACTIVITY, 0, -1)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

        for index, row in ipairs(rows) do
            vim.api.nvim_buf_set_extmark(bufnr, NS_ACTIVITY, index - 1, 0, {
                end_col = #(OP_MARKER[row.op] or "~"),
                hl_group = OP_HL[row.op] or OP_HL.edit,
            })
            if row.seq > self._last_viewed_seq then
                vim.api.nvim_buf_set_extmark(bufnr, NS_ACTIVITY, index - 1, 0, {
                    sign_text = UNSEEN_MARKER,
                    sign_hl_group = Theme.HL_GROUPS.ACTIVITY_UNSEEN,
                })
            end
        end

        return true
    end)

    if rendered then
        self._on_change(self)
    end
end

--- @private
function FileActivity:_open_row_under_cursor()
    local row = self:row_at(vim.api.nvim_win_get_cursor(0)[1])
    if not row then
        return
    end

    local first = row.ranges[1]
    -- `open_in_tab` reproduces the caller's screen row in the opened window so
    -- a chat→file jump doesn't move the eye. Reproducing this panel's row would
    -- put the target in the top few lines of a full-height window, so ask for
    -- the middle instead.
    DiffJump.open_in_tab(row.path, {
        file_row = first and first.start_line or 1,
        file_col = 0,
        exact = first ~= nil,
    }, math.floor(vim.o.lines / 2))
end

--- @private
function FileActivity:_setup_keybindings()
    BufHelpers.keymap_set(self._bufnr, "n", "<CR>", function()
        self:_open_row_under_cursor()
    end, { nowait = true, desc = "Agentic: Open file under cursor" })

    BufHelpers.keymap_set(self._bufnr, "n", "Q", function()
        local count = self:to_quickfix()
        Logger.notify(
            string.format("%d file(s) sent to the quickfix list", count),
            vim.log.levels.INFO,
            { title = "Agentic" }
        )
    end, { nowait = true, desc = "Agentic: Send file activity to quickfix" })
end

return FileActivity
