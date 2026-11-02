local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

local DEBOUNCE_MS = 200

--- The last lines of a file another process appends to, reported as they
--- change.
--- @class agentic.utils.FileTail
--- @field _path string
--- @field _max_lines integer
--- @field _on_rows fun(rows: string[])
--- @field _watch? uv.uv_fs_event_t
--- @field _timer uv.uv_timer_t
--- @field _rows? string[] Rows last reported
--- @field _stopped boolean
local FileTail = {}
FileTail.__index = FileTail

--- Watch `path` and call `on_rows` with its last `max_lines` lines: once
--- before returning, then whenever they change. One read follows each burst of
--- changes, `DEBOUNCE_MS` after its first. A missing file reports nothing;
--- other watch and read errors notify.
--- @param path string Absolute path
--- @param max_lines integer
--- @param on_rows fun(rows: string[]) Called on the main loop
--- @return agentic.utils.FileTail|nil tail
--- @return string|nil error
function FileTail:new(path, max_lines, on_rows)
    local timer, timer_err = vim.uv.new_timer()
    if not timer then
        return nil, timer_err
    end
    self = setmetatable({
        _path = path,
        _max_lines = max_lines,
        _on_rows = on_rows,
        _timer = timer,
        _stopped = false,
    }, self)

    local watch, watch_err = FileSystem.watch(path, function(err)
        self:_on_change(err)
    end)
    if not watch then
        timer:close()
        return nil, watch_err
    end
    self._watch = watch
    -- After the watch starts, so no write falls between the two.
    self:_read()
    return self, nil
end

--- Start the burst's read unless one is pending.
--- @param err string|nil The watch's error
function FileTail:_on_change(err)
    if self._stopped then
        return
    end
    if err then
        Logger.notify("Agentic: watch of " .. self._path .. " failed: " .. err)
        return
    end
    if not self._timer:is_active() then
        self._timer:start(
            DEBOUNCE_MS,
            0,
            vim.schedule_wrap(function()
                self:_read()
            end)
        )
    end
end

--- Read the last lines and report them if they changed.
function FileTail:_read()
    if self._stopped then
        return
    end
    local rows, err = FileSystem.read_last_lines(self._path, self._max_lines)
    if not rows then
        -- The writer may remove its file when done.
        if vim.uv.fs_stat(self._path) then
            Logger.notify("Agentic: cannot read " .. self._path .. ": " .. err)
        end
        return
    end
    if not vim.deep_equal(rows, self._rows) then
        self._rows = rows
        self._on_rows(rows)
    end
end

--- Stop watching. Idempotent.
function FileTail:stop()
    if self._stopped then
        return
    end
    self._stopped = true
    if self._watch then
        self._watch:stop()
        self._watch:close()
    end
    self._timer:stop()
    self._timer:close()
end

return FileTail
