--- One-shot chat completions against an OpenAI-compatible API, through curl.

local Config = require("agentic.config")
local Json = require("agentic.utils.json")

--- @class agentic.utils.TextModel.Request
--- @field model string Model id as the endpoint names it
--- @field system? string
--- @field input string
--- @field max_tokens? integer

--- @class agentic.utils.TextModel
local M = {}

--- @return boolean available True when `Config.text_model.url` is set
function M.available()
    return Config.text_model.url ~= nil
end

--- JSON body of a chat completion request.
--- @param request agentic.utils.TextModel.Request
--- @return string body
local function encode_body(request)
    local messages = {}
    if request.system then
        table.insert(messages, { role = "system", content = request.system })
    end
    table.insert(messages, { role = "user", content = request.input })
    return vim.json.encode({
        model = request.model,
        messages = messages,
        max_tokens = request.max_tokens,
    })
end

--- curl config text setting a bearer Authorization header.
--- @param key string
--- @return string config One `header = "..."` line
local function auth_config(key)
    local escaped = key:gsub('[\\"]', "\\%0")
    return ('header = "Authorization: Bearer %s"\n'):format(escaped)
end

--- Reply text of a chat completion response.
--- @param stdout string Response body
--- @return string|nil text
--- @return string|nil err
local function parse_reply(stdout)
    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok or type(decoded) ~= "table" then
        return nil, "undecodable reply: " .. stdout
    end
    local choice = type(decoded.choices) == "table" and decoded.choices[1]
    local message = type(choice) == "table" and Json.present(choice.message)
    local content = type(message) == "table" and Json.present(message.content)
    if type(content) ~= "string" then
        return nil, "no reply text: " .. stdout
    end
    return content
end

--- Error text of a failed curl run.
--- @param result vim.SystemCompleted
--- @param timeout_ms integer
--- @return string err
local function run_error(result, timeout_ms)
    -- `:h vim.system()` {timeout}: exit code 124. A TERM signal alone is a
    -- `kill()` of the job.
    if result.code == 124 then
        return ("timeout after %d ms"):format(timeout_ms)
    end
    local parts = vim.tbl_filter(function(part)
        return part ~= ""
    end, { vim.trim(result.stderr or ""), vim.trim(result.stdout or "") })
    if #parts == 0 then
        return ("curl exited with code %d, signal %d"):format(
            result.code,
            result.signal
        )
    end
    return table.concat(parts, "\n")
end

--- Run one chat completion. `on_done` runs on the main loop with the
--- reply's text, or nil and an error string.
--- @param request agentic.utils.TextModel.Request
--- @param on_done fun(text: string|nil, err: string|nil)
--- @return vim.SystemObj|nil job Nil when `text_model.url` or the key env var is unset, or curl fails to start (on_done is scheduled with an error)
function M.complete(request, on_done)
    local cfg = Config.text_model
    local function fail(err)
        vim.schedule(function()
            on_done(nil, err)
        end)
    end

    if not M.available() then
        fail("text_model.url is not set")
        return nil
    end

    local stdin = ""
    if cfg.api_key_env then
        local key = vim.env[cfg.api_key_env]
        if not key then
            fail(("$%s is not set"):format(cfg.api_key_env))
            return nil
        end
        stdin = auth_config(key)
    end

    local body_path = vim.fn.tempname()
    local f, open_err = io.open(body_path, "w")
    if not f then
        fail(open_err)
        return nil
    end
    f:write(encode_body(request))
    f:close()

    local endpoint = cfg.url:gsub("/+$", "") .. "/chat/completions"
    local timeout_ms = cfg.timeout_ms
    local ok, job = pcall(vim.system, {
        "curl",
        "-sS",
        "--fail-with-body",
        -- Key config on stdin, never on argv, where `ps` would show it.
        "-K",
        "-",
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        "@" .. body_path,
        endpoint,
    }, { stdin = stdin, text = true, timeout = timeout_ms }, function(
        result
    )
        os.remove(body_path)
        local text, err
        if result.code ~= 0 or result.signal ~= 0 then
            err = run_error(result, timeout_ms)
        else
            text, err = parse_reply(result.stdout or "")
        end
        vim.schedule(function()
            on_done(text, err)
        end)
    end)
    if not ok then
        os.remove(body_path)
        fail(job)
        return nil
    end
    return job
end

return M
