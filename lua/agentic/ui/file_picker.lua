local FileSystem = require("agentic.utils.file_system")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.FilePickerFile
--- @field path string Relative file path

--- @class agentic.ui.FilePicker
--- @field _files agentic.ui.FilePickerFile[]
local FilePicker = {}
FilePicker.__index = FilePicker

FilePicker.CMD_RG = {
    "rg",
    "--files",
    "--color",
    "never",
    "--hidden",
    "--glob",
    "!.git", -- Exclude .git (both directory and file used in worktrees)
}

FilePicker.CMD_FD = {
    "fd",
    "--type",
    "f",
    "--color",
    "never",
    "--hidden",
    "--exclude",
    ".git", -- Exclude .git (both directory and file used in worktrees)
}

FilePicker.CMD_GIT = { "git", "ls-files", "-co", "--exclude-standard" }

--- Buffer-local storage (weak values for automatic cleanup)
local instances_by_buffer = setmetatable({}, { __mode = "v" })

--- @param bufnr number
--- @return agentic.ui.FilePicker|nil
function FilePicker:new(bufnr)
    if not Config.file_picker.enabled then
        return nil
    end

    --- @type agentic.ui.FilePicker
    local instance = setmetatable({ _files = {}, _scanning = false }, self)
    instances_by_buffer[bufnr] = instance

    -- Pre-populate file cache asynchronously so @-completion doesn't block
    instance:scan_files_async()

    return instance
end

--- Get cached file list for a buffer, scanning if empty.
--- Called by the LSP completion server.
--- @param bufnr integer
--- @return agentic.ui.FilePickerFile[]
function FilePicker.get_files(bufnr)
    local instance = instances_by_buffer[bufnr]
    if not instance then
        return {}
    end

    if #instance._files == 0 and not instance._scanning then
        instance:scan_files()
    end

    return instance._files
end

function FilePicker:scan_files()
    local commands = self:_build_scan_commands()

    -- Try each command until one succeeds
    for _, cmd_parts in ipairs(commands) do
        Logger.debug("[FilePicker] Trying command:", vim.inspect(cmd_parts))
        local start_time = vim.uv.hrtime()

        local output = vim.fn.system(cmd_parts)
        local elapsed = (vim.uv.hrtime() - start_time) / 1e6

        Logger.debug(
            string.format(
                "[FilePicker] Command completed in %.2fms, exit_code: %d",
                elapsed,
                vim.v.shell_error
            )
        )

        if vim.v.shell_error == 0 and output ~= "" then
            local files = {}
            for line in output:gmatch("[^\n]+") do
                if line ~= "" then
                    local relative_path = FileSystem.to_smart_path(line)
                    table.insert(files, { path = relative_path })
                end
            end

            table.sort(files, function(a, b)
                return a.path < b.path
            end)

            self._files = files
            return files
        end
    end

    -- Fallback to glob if all commands failed
    Logger.debug("[FilePicker] All commands failed, using glob fallback")
    local files = {}
    local seen = {}
    -- Get all files including hidden files (dotfiles) and files inside hidden directories
    -- Note: vim.fn.glob() doesn't support brace expansion, so we need separate calls
    local glob_files = vim.fn.glob("**/*", false, true) -- Regular files
    local hidden_files = vim.fn.glob("**/.*", false, true) -- Dotfiles at any depth
    local files_in_hidden = vim.fn.glob("**/.*/**/*", false, true) -- Files inside dot dirs
    vim.list_extend(glob_files, hidden_files)
    vim.list_extend(glob_files, files_in_hidden)
    Logger.debug("[FilePicker] Glob returned", #glob_files, "paths")

    for _, path in ipairs(glob_files) do
        if vim.fn.isdirectory(path) == 0 and not self:_should_exclude(path) then
            local relative_path = FileSystem.to_smart_path(path)
            if not seen[relative_path] then
                seen[relative_path] = true
                table.insert(files, { path = relative_path })
            end
        end
    end

    table.sort(files, function(a, b)
        return a.path < b.path
    end)

    self._files = files
    return files
end

--- Asynchronously scan files and populate the cache.
--- Uses vim.system() for non-blocking execution. Falls back to synchronous
--- glob on next get_files() call if all async commands fail.
function FilePicker:scan_files_async()
    if self._scanning then
        return
    end

    local commands = self:_build_scan_commands()
    if #commands == 0 then
        -- No external commands available; synchronous glob fallback on first use
        return
    end

    self._scanning = true
    self:_try_async_command(commands, 1)
end

--- Try command at index `idx`; on failure, try the next one.
--- @param commands table[]
--- @param idx integer
function FilePicker:_try_async_command(commands, idx)
    if idx > #commands then
        self._scanning = false
        return
    end

    local start_time = vim.uv.hrtime()
    vim.system(commands[idx], { text = true }, function(result)
        vim.schedule(function()
            local elapsed = (vim.uv.hrtime() - start_time) / 1e6
            Logger.debug(
                string.format(
                    "[FilePicker] Async command completed in %.2fms, exit_code: %d",
                    elapsed,
                    result.code
                )
            )

            if result.code == 0 and result.stdout and result.stdout ~= "" then
                local files = {}
                for line in result.stdout:gmatch("[^\n]+") do
                    if line ~= "" then
                        local relative_path = FileSystem.to_smart_path(line)
                        table.insert(files, { path = relative_path })
                    end
                end
                table.sort(files, function(a, b)
                    return a.path < b.path
                end)
                self._files = files
                self._scanning = false
            else
                -- Try next command
                self:_try_async_command(commands, idx + 1)
            end
        end)
    end)
end

--- Builds list of all available scan commands to try in order
--- All commands run in current working directory by default
--- @return table[] commands List of command arrays to try
function FilePicker:_build_scan_commands()
    local commands = {}

    if vim.fn.executable(FilePicker.CMD_RG[1]) == 1 then
        table.insert(commands, vim.list_extend({}, FilePicker.CMD_RG))
    end

    if vim.fn.executable(FilePicker.CMD_FD[1]) == 1 then
        table.insert(commands, vim.list_extend({}, FilePicker.CMD_FD))
    end

    if vim.fn.executable(FilePicker.CMD_GIT[1]) == 1 then
        local _ = vim.fn.system("git rev-parse --git-dir 2>/dev/null")
        if vim.v.shell_error == 0 then
            table.insert(commands, vim.list_extend({}, FilePicker.CMD_GIT))
        end
    end

    return commands
end

--- used exclusively with glob fallback to exclude common unwanted files
FilePicker.GLOB_EXCLUDE_PATTERNS = {
    "^%.$",
    "^%.%.$",
    "%.git/",
    "^%.git$", -- Exclude .git (both directory and file used in worktrees)
    "%.DS_Store$",
    "node_modules/",
    "%.pyc$",
    "%.swp$",
    "__pycache__/",
    "dist/",
    "build/",
    "vendor/",
    "%.next/",
    -- Java/JVM
    "target/",
    "%.gradle/",
    "%.m2/",
    -- Ruby
    "%.bundle/",
    -- Build/Cache
    "%.cache/",
    "%.turbo/",
    "/out/", -- Build output directory (anchored to avoid matching "layout/")
    -- Coverage
    "coverage/",
    "%.nyc_output/",
    -- Package managers
    "%.npm/",
    "%.yarn/",
    "%.pnpm%-store/",
    "bower_components/",
}

--- Checks if path should be excluded from the file list
--- Necessary when using glob fallback, since it can't exclude files
--- @param path string
--- @return boolean
function FilePicker:_should_exclude(path)
    for _, pattern in ipairs(FilePicker.GLOB_EXCLUDE_PATTERNS) do
        if path:match(pattern) then
            return true
        end
    end

    return false
end

return FilePicker
