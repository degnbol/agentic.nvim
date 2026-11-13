local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")

--- @class agentic.utils.FileSystem
local FileSystem = {}

FileSystem.IMAGE_MIMES = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    webp = "image/webp",
    bmp = "image/bmp",
    svg = "image/svg+xml",
    avif = "image/avif",
    heic = "image/heic",
    heif = "image/heif",
    tiff = "image/tiff",
    tif = "image/tiff",
    ico = "image/x-icon",
}

FileSystem.AUDIO_MIMES = {
    mp3 = "audio/mpeg",
    wav = "audio/wav",
    ogg = "audio/ogg",
    flac = "audio/flac",
    aac = "audio/aac",
    m4a = "audio/mp4",
    wma = "audio/x-ms-wma",
    opus = "audio/opus",
    webm = "audio/webm",
    aiff = "audio/aiff",
    ape = "audio/ape",
}

--- Read the file content directly from disk, bypassing any loaded buffer.
--- Use when the on-disk version is authoritative (e.g. provider edits).
--- CRLF is normalised to LF, so the returned lines do not preserve the file's
--- byte count.
--- @param abs_path string
--- @return string[]|nil lines
--- @return string|nil error
function FileSystem.read_from_disk(abs_path)
    local stat = vim.uv.fs_stat(abs_path)
    if stat and stat.type == "directory" then
        return nil, "Cannot read a directory as file: " .. abs_path
    end

    local file, open_err = io.open(abs_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        content = (content or ""):gsub("\r\n", "\n")
        return vim.split(content, "\n"), nil
    end

    return nil, (open_err or ("Failed to open file: " .. abs_path))
end

--- Read a JSON file from disk and decode it.
--- @param abs_path string
--- @return any|nil value nil when the file cannot be read or decoded
--- @return string|nil error
function FileSystem.read_json(abs_path)
    local lines, read_err = FileSystem.read_from_disk(abs_path)
    if not lines then
        return nil, read_err
    end
    local ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not ok then
        return nil, "JSON decode error in " .. abs_path .. ": " .. value
    end
    return value, nil
end

--- The decoded JSON file at `path`. Nil when it is missing, or when it
--- exists but cannot be read or decoded, which warns.
--- @param path string
--- @return any|nil value
function FileSystem.read_json_if_present(path)
    local data, err = FileSystem.read_json(path)
    if err and vim.uv.fs_stat(path) then
        Logger.notify(err, vim.log.levels.WARN)
    end
    return data
end

--- Modification time of a file.
--- @param path string
--- @return number mtime seconds; 0 when the file does not exist
function FileSystem.mtime(path)
    local stat = vim.uv.fs_stat(path)
    return stat and stat.mtime.sec or 0
end

--- Read whole lines appended to a file since a byte offset.
---
--- For tailing a file another process appends to: the tail may end mid-line, so
--- `new_offset` points just past the last complete line and the remainder is
--- left for the next call — no remainder state to carry. A file shorter than
--- `offset` — truncated, rotated or replaced — is read from the start.
--- @param abs_path string
--- @param offset integer bytes already consumed
--- @return string[]|nil lines complete lines appended since `offset`
--- @return integer new_offset unchanged from `offset` on error
--- @return string|nil error
function FileSystem.read_appended(abs_path, offset)
    -- Not `read_from_disk`, whose CRLF normalisation desynchronises the offset
    -- from the file's bytes.
    local file, open_err = io.open(abs_path, "rb")
    if not file then
        return nil, offset, (open_err or ("Failed to open file: " .. abs_path))
    end

    local size = file:seek("end")
    -- Restart rather than seek past EOF, which would yield nothing forever.
    local start = size < offset and 0 or offset
    file:seek("set", start)
    local tail = file:read("*a") or ""
    file:close()

    -- Anchored at the end, so this is the last newline in the tail.
    local last_newline = tail:find("\n[^\n]*$")
    if not last_newline then
        return {}, start, nil
    end

    return vim.split(tail:sub(1, last_newline - 1), "\n"),
        start + last_newline,
        nil
end

local LAST_LINES_WINDOW = 64 * 1024

--- The last lines of a file, read from at most its last 64 KiB, so the cost
--- does not grow with the file. A read that does not start at the file's
--- first byte drops its first line, which may be partial. A last line without
--- a newline is included, as `tail` does.
--- @param abs_path string
--- @param max_lines integer
--- @return string[]|nil lines
--- @return string|nil error
function FileSystem.read_last_lines(abs_path, max_lines)
    local file, open_err = io.open(abs_path, "rb")
    if not file then
        return nil, (open_err or ("Failed to open file: " .. abs_path))
    end

    local size = file:seek("end")
    local start = math.max(0, size - LAST_LINES_WINDOW)
    file:seek("set", start)
    local text = file:read("*a") or ""
    file:close()

    local lines = vim.split(text, "\n")
    if lines[#lines] == "" then
        table.remove(lines)
    end
    if start > 0 then
        table.remove(lines, 1)
    end
    return vim.list_slice(lines, math.max(1, #lines - max_lines + 1)), nil
end

--- The loaded buffer for the file at `path`. Never a buffer whose name only
--- contains `path`.
--- @param path string Absolute or relative to the cwd
--- @return integer|nil bufnr
local function loaded_buffer(path)
    -- Not `bufnr()`: a pattern match that, when no buffer has the name, falls
    -- back to one whose name only contains it. Compared by identity, as a
    -- buffer name keeps directory symlinks resolved or not depending on
    -- whether the directory existed when the buffer was named.
    local file = FileSystem.canonical_path(path)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        if
            name ~= ""
            and vim.api.nvim_buf_is_loaded(bufnr)
            and FileSystem.canonical_path(name) == file
        then
            return bufnr
        end
    end
    return nil
end

--- Read the file content from a buffer if loaded, to get unsaved changes,
--- or from disk otherwise
--- @param abs_path string
--- @return string[]|nil lines
--- @return string|nil error
function FileSystem.read_from_buffer_or_disk(abs_path)
    local bufnr = loaded_buffer(abs_path)

    if bufnr then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        return lines, nil
    end

    return FileSystem.read_from_disk(abs_path)
end

--- Save content to disk at the given absolute path
--- @param abs_path string
--- @param content string
--- @return boolean success
--- @return string|nil error
function FileSystem.save_to_disk(abs_path, content)
    local file, open_err = io.open(abs_path, "w")

    if file then
        local ok, err = pcall(file.write, file, content)
        file:close()
        if ok then
            return true, nil
        else
            return false, "Failed to write content: " .. tostring(err)
        end
    end

    return false,
        "Failed to open file for writing: "
            .. abs_path
            .. ". Error: "
            .. tostring(open_err)
end

--- Replace a file's content atomically, creating its parent directory: a
--- reader sees the old or the new content, never a partial file, also with
--- writers in other processes.
--- @param abs_path string
--- @param content string
--- @return boolean success
--- @return string|nil error
function FileSystem.write_atomic(abs_path, content)
    local dir_ok, dir_err = FileSystem.mkdirp(vim.fs.dirname(abs_path))
    if not dir_ok then
        return false, dir_err
    end
    -- Per process, so concurrent writers do not share it.
    local tmp = abs_path .. "." .. vim.uv.os_getpid() .. ".tmp"
    local saved, save_err = FileSystem.save_to_disk(tmp, content)
    if not saved then
        return false, save_err
    end
    -- Unlike `os.rename`, replaces an existing file on Windows too.
    local renamed, rename_err = vim.uv.fs_rename(tmp, abs_path)
    if not renamed then
        os.remove(tmp)
        return false, rename_err
    end
    return true, nil
end

--- Watch a file for changes, including its creation and its replacement by a
--- rename. Creates the parent directory when missing.
--- @param abs_path string
--- @param on_change fun(err: string|nil) Called on the main loop, with the watch's error if it fails
--- @return uv.uv_fs_event_t|nil handle Stop it with `handle:stop()`
--- @return string|nil error
function FileSystem.watch(abs_path, on_change)
    local dir = vim.fs.dirname(abs_path)
    local dir_ok, dir_err = FileSystem.mkdirp(dir)
    if not dir_ok then
        return nil, dir_err
    end
    local handle, new_err = vim.uv.new_fs_event()
    if not handle then
        return nil, new_err
    end
    local name = vim.fs.basename(abs_path)
    local callback = vim.schedule_wrap(on_change)
    -- The directory, since a watch on the file fails while it is missing and
    -- stays on the old inode after a replace.
    local started, start_err = handle:start(dir, {}, function(err, filename)
        if err then
            callback(err)
        elseif filename == name then
            callback(nil)
        end
    end)
    if not started then
        handle:close()
        return nil, start_err
    end
    return handle, nil
end

--- Replace the lines of the loaded buffer for the file at `path` with the
--- file on disk and mark it unmodified. Keeps its 'modifiable' value.
--- No-op when no buffer is loaded for the file or the file cannot be read.
--- @param path string Absolute or relative to the cwd
function FileSystem.reload_buffer(path)
    local bufnr = loaded_buffer(path)
    if not bufnr then
        return
    end
    local disk_lines = FileSystem.read_from_disk(path)
    if not disk_lines then
        return
    end
    -- Not `:edit!`: inside `nvim_buf_call` that fires autocmds (BufReadPost,
    -- FileType, swap file dialog) in the wrong window context (curwin doesn't
    -- match curbuf), causing crashes and [O]k prompts.
    BufHelpers.with_modifiable(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, disk_lines)
        vim.bo[bufnr].modified = false
    end)
end

--- @param abs_path string
--- @param content string
--- @param callback fun(error: string|nil)
function FileSystem.write_file(abs_path, content, callback)
    local saved, err = FileSystem.save_to_disk(abs_path, content)

    if saved then
        FileSystem.reload_buffer(abs_path)
        callback(nil)
        return
    end

    callback(err or ("Failed to write file: " .. abs_path))
end

--- @param path string
--- @return string the base64-encoded content of the file or an empty string otherwise
function FileSystem.read_file_base64(path)
    local file = io.open(path, "rb")
    if not file then
        Logger.notify("Failed to open file to read base64: " .. path)
        return ""
    end

    local content = file:read("*a")
    file:close()

    return vim.base64.encode(content)
end

--- @param path string
function FileSystem.to_absolute_path(path)
    return vim.fn.fnamemodify(path, ":p")
end

--- Absolute, normalized form of `path`, where a relative `path` is taken
--- relative to `cwd`. `~` is expanded. `$VAR` is kept as text.
--- @param path string
--- @param cwd string absolute
--- @return string
function FileSystem.resolve(path, cwd)
    local opts = { expand_env = false }
    local normalized = vim.fs.normalize(path, opts)
    if normalized:sub(1, 1) == "/" then
        return normalized
    end
    return vim.fs.normalize(vim.fs.joinpath(cwd, normalized), opts)
end

--- Convert a path to a "smart" path, which is:
--- - absolute if outside the current working directory
--- - relative to the current working directory
--- - or uses ~ for home directory
--- The current working directory itself, and `""`, give `""`.
--- @param path string
--- @return string
function FileSystem.to_smart_path(path)
    return vim.fn.fnamemodify(path, ":p:~:.")
end

--- Whether `path` names an existing regular file. A directory of that name is
--- not one, which bare `fs_stat` would not distinguish.
--- @param path string
--- @return boolean
function FileSystem.is_file(path)
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == "file"
end

--- The bytes of a regular file of at most `max_bytes`. A fifo or device is
--- not read, as reading it may block or never end.
--- @param path string
--- @param max_bytes integer
--- @return string|nil bytes nil for a larger file, any other file type, or
---         when a stat or read fails
function FileSystem.read_regular_file(path, max_bytes)
    local st = vim.uv.fs_stat(path)
    if not st or st.type ~= "file" or st.size > max_bytes then
        return nil
    end
    local fd = vim.uv.fs_open(path, "r", 438)
    if not fd then
        return nil
    end
    local data = vim.uv.fs_read(fd, st.size, 0)
    vim.uv.fs_close(fd)
    return data --[[@as string|nil]]
end

--- Absolute path with symlinked directory components resolved, usable as a
--- map key that identifies a file by identity rather than by spelling.
---
--- `vim.fs.normalize` does not resolve symlinks, so the same file reached
--- through a symlinked prefix yields two different keys — on macOS `/tmp/x`
--- and `/private/tmp/x`, or a symlinked config directory and the repository it
--- points into. `vim.uv.fs_realpath` collapses those but returns nil for a
--- path that does not exist yet, which is every file at the moment it is
--- created — so resolve the deepest existing ancestor and re-join the
--- remaining tail.
--- @param path string
--- @return string
function FileSystem.canonical_path(path)
    local absolute =
        vim.fs.normalize(vim.fn.fnamemodify(path, ":p"), { expand_env = false })

    --- @type string[]
    local tail = {}
    local prefix = absolute
    while prefix ~= "" and prefix ~= "/" do
        local resolved = vim.uv.fs_realpath(prefix)
        if resolved then
            if #tail == 0 then
                return resolved
            end
            return vim.fs.joinpath(resolved, table.concat(tail, "/"))
        end
        table.insert(tail, 1, vim.fs.basename(prefix))
        prefix = vim.fs.dirname(prefix)
    end

    return absolute
end

--- @param file_path string
--- @return string
function FileSystem.get_file_extension(file_path)
    return vim.fn.fnamemodify(file_path, ":e"):lower()
end

--- Create directory recursively (equivalent to mkdir -p). Kept as a named
--- function (not inlined) because chat_history.test.lua stubs it.
--- @param path string
--- @return boolean success
--- @return string|nil error
function FileSystem.mkdirp(path)
    local ok, ret = pcall(vim.fn.mkdir, path, "p")
    if not ok then
        return false, tostring(ret)
    end
    if ret == 0 then
        return false, "failed to create directory: " .. path
    end
    return true, nil
end

return FileSystem
