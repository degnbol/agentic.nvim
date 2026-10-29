local FileSystem = require("agentic.utils.file_system")
local ContextList = require("agentic.ui.context_list")

--- @class agentic.ui.FileList : agentic.ui.ContextList
--- @field protected __items string[]
local FileList = setmetatable({}, { __index = ContextList })
FileList.__index = FileList

--- Add a file to the list if not already present
--- @param file_path string
--- @return boolean success
function FileList:add(file_path)
    for _, path in ipairs(self.__items) do
        if path == file_path then
            return true
        end
    end

    local stat = vim.uv.fs_stat(file_path)

    if stat and stat.type == "file" then
        table.insert(self.__items, file_path)
        self:render()
        return true
    end

    return false
end

--- @protected
--- @param path string
--- @return string[] rows
function FileList:__rows(path)
    return { "-   " .. FileSystem.to_smart_path(path) }
end

return FileList
