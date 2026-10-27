--- @class agentic.utils.RotatingFile
local RotatingFile = {}

--- Append `text` to `path`. Once the file holds at least `max_bytes`, move it
--- to `path .. ".1"`, replacing any earlier backup.
--- @param path string
--- @param text string
--- @param max_bytes integer
--- @return boolean ok
--- @return string|nil err
function RotatingFile.append(path, text, max_bytes)
    local file, open_err = io.open(path, "a")
    if not file then
        return false, open_err
    end
    local written, write_err = file:write(text)
    local size, seek_err = file:seek("end")
    local closed, close_err = file:close()
    if not (written and size and closed) then
        return false, write_err or seek_err or close_err
    end

    if size < max_bytes then
        return true
    end

    local backup = path .. ".1"
    -- os.rename onto an existing file fails on Windows. The result is ignored
    -- because the first rotation has no backup to remove.
    os.remove(backup)
    local ok, rename_err = os.rename(path, backup)
    if not ok then
        return false, rename_err
    end
    return true
end

return RotatingFile
