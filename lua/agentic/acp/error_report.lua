--- Classify an ACP error and build its display lines. The classification is
--- claude-agent-acp bridge heuristics (`errorKind`, embedded Anthropic error
--- JSON, the usage-limit reset clause); any other error falls back to its
--- message without the bridge wrapper.
--- @class agentic.acp.ErrorReport
local M = {}

--- Hints for known error classes. Keyed by both the Anthropic `error.type`
--- strings the embedded-JSON path produces and the internal classes the
--- errorKind map resolves to. authentication_error has no hint.
--- @type table<string, string>
local error_hints = {
    overloaded_error = "The API is overloaded. Try again in a moment.",
    rate_limit_error = "Rate limited. Wait a moment before retrying.",
    billing_error = "Organisation spend limit reached — no automatic retry. "
        .. "Ask an admin to raise the cap, or run /usage-credits to request "
        .. "an increase.",
}

--- ACP bridge structured error kind → internal error class. The bridge attaches
--- `errorKind` to the JSON-RPC error `data` so clients classify without parsing
--- human-readable message text. Only kinds with confident recovery semantics are
--- mapped; unmapped kinds fall through to the text heuristics below.
--- @type table<string, string>
local error_kind_class = {
    authentication_failed = "authentication_error",
    oauth_org_not_allowed = "authentication_error",
    billing_error = "billing_error",
}

--- Strip the bridge's `Internal error: ` wrapper. It names the transport the
--- failure came back over, never the failure.
--- @param msg string
--- @return string stripped
local function strip_bridge_wrapper(msg)
    return (msg:gsub("^Internal error:%s*", ""))
end

--- Strip the bridge's wrapper and the `API Error: NNN` status behind it.
---
--- Only for a message whose class is already known, where a hint below says
--- what the status would have. On an unclassified message the status is the
--- one machine-readable fact in the line, and dropping it can leave nothing at
--- all: `API Error: 401` is entirely prefix.
--- @param msg string
--- @return string stripped
local function strip_error_prefix(msg)
    return (strip_bridge_wrapper(msg):gsub("^API Error:%s*%d+%s*", ""))
end

--- Parse a reset time like "5pm (Europe/London)" or "17:30 (Europe/London)"
--- into epoch seconds. Returns nil if parsing fails.
--- @param time_str string e.g. "5pm", "5:30pm", "17:00"
--- @param tz string e.g. "Europe/London"
--- @return number|nil epoch
function M.parse_reset_time(time_str, tz)
    -- Use GNU date to parse the time in the given timezone
    local result = vim.system(
        { "date", "-d", "today " .. time_str, "+%s" },
        { env = { TZ = tz }, text = true }
    ):wait()
    local epoch = tonumber(vim.trim(result.stdout or ""))
    if not epoch then
        return nil
    end
    -- If the parsed time is in the past, it means tomorrow
    if epoch <= os.time() then
        epoch = epoch + 86400
    end
    return epoch
end

--- Format an ACP error into human-readable lines.
--- Classification prefers the bridge's structured `err.data.errorKind`; text
--- heuristics (embedded JSON, then usage-limit regex) supply the display lines
--- and the fallback class for errors/bridges that lack errorKind.
---
--- Example input message:
---   "Internal error: Failed to authenticate. API Error: 401\n
---    {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",
---    \"message\":\"Invalid authentication credentials\"}}"
--- Output: {"401 Invalid authentication credentials"}
--- @param err agentic.acp.ACPError
--- @return string[] lines
--- @return string|nil error_type Error class (from errorKind if present, else text)
--- @return number|nil reset_epoch Epoch seconds when usage resets (for usage_limit errors)
function M.format(err)
    local lines = {}
    local msg = err.message or "Unknown error"

    -- The bridge attaches a structured errorKind to err.data; it is
    -- authoritative for classification because message wording is a display
    -- artefact that can change upstream and silently break text matching. The
    -- text paths below still build the display lines (richer when structured
    -- JSON or a reset clause is present) and supply the fallback class.
    local kind_class
    if type(err.data) == "table" then
        kind_class = error_kind_class[err.data.errorKind]
    end

    -- Try to extract embedded JSON from messages like:
    -- 'Internal error: API Error: 529\n{"type":"error","error":{"type":"overloaded_error","message":"Overloaded."}}'
    local json_str = msg:match("%b{}")
    if json_str then
        local ok, parsed = pcall(vim.json.decode, json_str)
        if ok and type(parsed) == "table" then
            local inner = parsed.error or parsed
            local error_type = inner.type or ""
            local error_msg = inner.message or ""

            -- Extract HTTP status code from prefix (e.g. "API Error: 401")
            local prefix = msg:sub(1, msg:find("{", 1, true) - 1)
            local http_code = prefix:match("(%d%d%d)%s*$")

            if http_code and error_msg ~= "" then
                table.insert(lines, http_code .. " " .. error_msg)
            elseif error_msg ~= "" then
                table.insert(lines, error_msg)
            elseif error_type ~= "" then
                local readable = error_type:gsub("_", " ")
                readable = readable:sub(1, 1):upper() .. readable:sub(2)
                table.insert(lines, readable)
            end

            -- Hint follows the resolved class (errorKind first) so a mapped
            -- kind that also carries embedded JSON keeps its class hint.
            local hint = error_hints[kind_class or error_type]
            if hint then
                table.insert(lines, "")
                table.insert(lines, hint)
            end

            local resolved_type = error_type ~= "" and error_type or nil
            return lines, kind_class or resolved_type
        end
    end

    -- errorKind classified with no richer structured JSON body (e.g. the
    -- billing spend cap): show the message with the wrapper prefix stripped,
    -- plus the class hint. Runs before the usage-limit scrape so a mapped kind
    -- is never reclassified as usage_limit or given a spurious reset epoch.
    if kind_class then
        vim.list_extend(
            lines,
            vim.split(strip_error_prefix(msg), "\n", { plain = true })
        )
        local hint = error_hints[kind_class]
        if hint then
            table.insert(lines, "")
            table.insert(lines, hint)
        end
        return lines, kind_class, nil
    end

    -- Unclassified from here down, so the message is all the reader gets: the
    -- lines keep the provider's words verbatim, without the bridge's wrapper.
    msg = strip_bridge_wrapper(msg)

    -- Detect usage limit errors: "You're out of extra usage · resets 5pm (Europe/London)"
    local time_str, tz = msg:match("resets%s+(%d+:?%d*%s*[ap]m)%s+%(([%w/]+)%)")
    if not time_str then
        -- Try 24h format: "resets 17:00 (Europe/London)"
        time_str, tz = msg:match("resets%s+(%d+:%d+)%s+%(([%w/]+)%)")
    end
    if time_str then
        vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
        local reset_epoch = M.parse_reset_time(time_str, tz)
        return lines, "usage_limit", reset_epoch
    end

    vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
    return lines, nil
end

--- What the error says in its own words: the lines of `format` up to the
--- first blank, which is where a class hint starts.
--- @param lines string[] Lines from `format`
--- @return string
function M.reported_text(lines)
    local said = {}
    for _, line in ipairs(lines) do
        if not line:match("%S") then
            break
        end
        said[#said + 1] = line
    end
    return table.concat(said, " ")
end

return M
