--- Claim extraction: a turn's checkable claims, by the text model.

local Config = require("agentic.config")
local Prompts = require("agentic.skeptic.prompts")
local TextModel = require("agentic.utils.text_model")

--- @class agentic.skeptic.Claims
local M = {}

--- The extractor's input: the turn's sections and the claims checked before.
--- @param turn agentic.skeptic.Turn
--- @param checked string[]
--- @return string
local function extract_input(turn, checked)
    return Prompts.join({
        Prompts.section("User prompts", turn.prompts),
        Prompts.section("Agent text", turn.text ~= "" and { turn.text } or {}),
        Prompts.section("Subagent reports", turn.reports),
        Prompts.section("Diffs", turn.diffs),
        Prompts.section("Claims already checked", checked),
    })
end

--- The claims in an extractor reply: a JSON array of strings, alone or in a
--- fenced block.
--- @param reply string
--- @return string[]|nil claims
--- @return string|nil err
function M.parse(reply)
    local json = reply:match("```%w*\n(.-)\n```") or reply
    local ok, decoded = pcall(vim.json.decode, vim.trim(json))
    if not ok or not vim.islist(decoded) then
        return nil, "the extractor did not answer a JSON array: " .. reply
    end
    for _, claim in ipairs(decoded) do
        if type(claim) ~= "string" then
            return nil, "the extractor answered a non-string claim: " .. reply
        end
    end
    return decoded
end

--- Extract the checkable claims of `turn`, leaving out those in `checked`.
--- `on_done` runs on the main loop.
--- @param turn agentic.skeptic.Turn
--- @param checked string[]
--- @param on_done fun(claims: string[]|nil, err: string|nil)
function M.extract(turn, checked, on_done)
    TextModel.complete({
        model = Config.skeptic.extractor.model,
        reasoning_effort = Config.skeptic.extractor.reasoning_effort or nil,
        system = Prompts.text("extract"),
        input = extract_input(turn, checked),
    }, function(text, err)
        if not text then
            on_done(nil, err)
            return
        end
        on_done(M.parse(text))
    end)
end

return M
