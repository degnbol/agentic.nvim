local Config = require("agentic.config")
local RotatingFile = require("agentic.utils.rotating_file")

--- @class agentic.utils.Logger
local Logger = {}

--- Absolute path of the folder holding the plugin's log. Resolved and created
--- at require time, as `vim.fn` cannot be called from fast events.
Logger.LOG_DIR = vim.fn.stdpath("log") .. "/agentic"
--- Absolute path of the plugin's log file.
Logger.LOG_FILE_PATH = Logger.LOG_DIR .. "/agentic.log"
local LOG_MAX_BYTES = 10 * 1024 * 1024

--- Write failures are reported once per nvim session, not once per message.
local reported_write_error = false

local function format_debug_message(...)
    local args = { ... }

    if #args == 0 then
        return nil
    end

    local info = debug.getinfo(3, "Sl")
    local caller_source = info.source:match("@(.+)$") or "unknown"
    local caller_module =
        caller_source:gsub("^.*/lua/", ""):gsub("%.lua$", ""):gsub("/", ".")

    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local log_parts = {
        string.format(
            "[%s] [%s:%d]",
            timestamp,
            caller_module,
            info.currentline
        ),
    }

    for _, arg in ipairs(args) do
        if type(arg) == "string" then
            table.insert(log_parts, arg)
        else
            table.insert(log_parts, vim.inspect(arg))
        end
    end

    return log_parts
end

--- @param msg string Content of the notification to show to the user.
--- @param level vim.log.levels|nil One of the values from `vim.log.levels`. Defaults to WARN
--- @param opts table|nil Optional parameters. Unused by default.
function Logger.notify(msg, level, opts)
    vim.schedule(function()
        local ok, res =
            pcall(vim.notify, msg, level or vim.log.levels.WARN, opts or {})

        if not ok then
            print(
                "Notification error: "
                    .. tostring(res)
                    .. " - Original message: "
                    .. msg
            )
        end
    end)
end

local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, Logger.LOG_DIR, "p")
if not mkdir_ok then
    Logger.notify("Log folder: " .. mkdir_err)
end

--- Print a debug message that can be read by `:messages`
function Logger.debug(...)
    if not Config.debug then
        return
    end

    local formatted_message = format_debug_message(...)

    if formatted_message then
        print(unpack(formatted_message))
    end
end

--- Append a debug message to `LOG_FILE_PATH`
function Logger.debug_to_file(...)
    if not Config.log then
        return
    end

    local log_parts = format_debug_message(...)
    if not log_parts then
        return
    end

    local log_message = table.concat(log_parts, " ")
        .. "\n\n"
        .. string.rep("=", 5)
        .. "\n\n"

    local ok, err =
        RotatingFile.append(Logger.LOG_FILE_PATH, log_message, LOG_MAX_BYTES)
    if not ok and not reported_write_error then
        reported_write_error = true
        Logger.notify("Debug log: " .. err)
    end
end

return Logger
