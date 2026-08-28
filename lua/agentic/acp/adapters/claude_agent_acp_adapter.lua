local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local ClaudeUtils = require("agentic.acp.adapters.claude_utils")

--- @class agentic.acp.ClaudeAgentRawInput : agentic.acp.RawInput
--- @field content? string For creating new files instead of new_string
--- @field subagent_type? string For sub-agent tasks (Task tool)
--- @field model? string Model used for sub-agent tasks
--- @field skill? string Skill name
--- @field args? string Arguments for the skill
--- @field offset? integer Line offset for range reads
--- @field limit? integer Line count for range reads

--- claude-agent-acp sends rawInput/title/kind on tool_call_update, not just tool_call
--- @class agentic.acp.ClaudeAgentToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawInput? agentic.acp.ClaudeAgentRawInput
--- @field title? string
--- @field kind? agentic.acp.ToolKind

--- @class agentic.acp.ClaudeAgentACPAdapter : agentic.acp.ACPClient
local ClaudeAgentACPAdapter = ACPClient.extend()

--- Separate a Bash tool call's description from its output. claude-agent-acp
--- sends `input.description` as the initial tool_call content and wraps
--- stdout/stderr in a ```console fence on completion (tools.js). Left alone,
--- the description seeds the body and accumulates ahead of the output behind a
--- "---" divider, and the renderer double-wraps the already-fenced output.
--- Lift the description to a title field and reduce the body to the unfenced
--- output, so the renderer shows the description as a heading and applies a
--- single fence.
--- @param message agentic.ui.MessageWriter.ToolCallBase
--- @param raw_input agentic.acp.ClaudeAgentRawInput|nil
local function lift_execute_description(message, raw_input)
    local desc = raw_input and raw_input.description
    local stripped, was_fenced = ClaudeUtils.strip_console_fence(message.body)
    if was_fenced then
        message.body = stripped
    else
        -- Unfenced content is the description echo, not output. Prefer the
        -- explicit rawInput field, fall back to the echoed text.
        if (not desc or desc == "") and message.body and #message.body > 0 then
            desc = table.concat(message.body, "\n")
        end
        message.body = nil
    end
    if type(desc) == "string" and desc ~= "" then
        message.description = desc
    end
end

--- Intercept mode-switching tools at the initial tool_call level before the
--- base class renders the body (which contains internal instructions).
--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__handle_tool_call(session_id, update)
    -- Provider sends kind="other" for EnterPlanMode but kind="switch_mode"
    -- for ExitPlanMode ("Ready to code?"). Check both.
    local mode_label = (update.kind == "other" or update.kind == "switch_mode")
        and ClaudeUtils.mode_switch_label(update.title)
    if mode_label then
        --- @type agentic.ui.MessageWriter.ToolCallBlock
        local message = {
            tool_call_id = update.toolCallId,
            kind = "switch_mode",
            status = update.status,
            argument = mode_label,
        }

        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_tool_call(message)
        end)
        return
    end

    update.title = ClaudeUtils.suppress_placeholder_title(update.title)

    ACPClient.__handle_tool_call(self, session_id, update)
end

--- Build the initial tool_call message, layering the same rawInput enrichment
--- as `__build_tool_call_update` on top of the base message.
---
--- Subagent (Task) tool calls carry `kind` + `rawInput` (and the edit diff) on
--- the INITIAL tool_call — nothing streams an empty one first, unlike top-level
--- calls whose diff arrives on a later tool_call_update. Without applying the
--- enrichment here, subagent Edit/Write calls render with no diff.
--- @protected
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBlock message
function ClaudeAgentACPAdapter:__build_tool_call_message(update)
    local message = ACPClient.__build_tool_call_message(self, update)
    local had_raw_input = update.rawInput
        and not vim.tbl_isempty(update.rawInput)
    self:__apply_raw_input(message, update)
    self:__apply_edit_diff(message, update)
    -- Top-level execute tool_calls arrive with empty rawInput (input streams
    -- separately), so __apply_raw_input's execute branch is skipped — lift the
    -- description echo out of the body here. Subagent execute carries rawInput
    -- and is already lifted inside __apply_raw_input.
    if message.kind == "execute" and not had_raw_input then
        lift_execute_description(message, update.rawInput)
    end
    return message
end

--- Build enriched update from rawInput fields that claude-agent-acp
--- sends on tool_call_update instead of tool_call.
--- @protected
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function ClaudeAgentACPAdapter:__build_tool_call_update(update)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
        body = self:extract_content_body(update),
    }
    if update.status == "failed" then
        message.failure_reason = self:extract_failure_reason(update.rawOutput)
    end

    self:__apply_raw_input(message, update)
    self:__apply_edit_diff(message, update)

    return message
end

--- Enrich a tool-call message from claude-agent-acp's rawInput fields (file
--- path, read range, fetch/subagent/skill/slash-command remaps, search
--- pattern, execute description). Shared by the initial `tool_call` and
--- follow-up `tool_call_update` paths — see `__build_tool_call_message` for
--- why the tool_call path needs it too. The edit diff is deliberately not
--- built here; see `__apply_edit_diff`.
--- @protected
--- @param message agentic.ui.MessageWriter.ToolCallBase
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__apply_raw_input(message, update)
    local rawInput = update.rawInput
    if not rawInput or vim.tbl_isempty(rawInput) then
        return
    end

    local kind = update.kind

    if kind == "read" or kind == "edit" then
        if rawInput.file_path then
            message.argument = FileSystem.to_smart_path(rawInput.file_path)
        end

        if kind == "read" then
            if rawInput.offset then
                message.read_range = {
                    offset = rawInput.offset,
                    limit = rawInput.limit,
                }
            elseif update.title then
                -- rawInput may lack offset/limit; fall back to parsing
                -- the title string e.g. "Read file.txt (10 - 42)"
                local a, b = update.title:match("%((%d+)%s*%-%s*(%d+)%)%s*$")
                if a then
                    local na = tonumber(a) --[[@as integer]]
                    local nb = tonumber(b) --[[@as integer]]
                    message.read_range = {
                        offset = na,
                        limit = nb - na + 1,
                    }
                end
            end
        end
    elseif kind == "fetch" then
        self:__resolve_fetch_fields(message, rawInput)
    elseif kind == "think" and rawInput.subagent_type then
        message.kind = "SubAgent"
        message.argument = rawInput.description or rawInput.subagent_type
    elseif
        kind == "SubAgent" or (kind == "other" and rawInput.subagent_type)
    then
        message.kind = "SubAgent"
        message.argument = string.format(
            "%s, %s: %s",
            rawInput.model or "default",
            rawInput.subagent_type or "",
            rawInput.description or ""
        )

        if rawInput.prompt then
            message.body = self:safe_split(rawInput.prompt)
        end
    elseif kind == "other" or kind == "switch_mode" then
        if update.title == "SlashCommand" then
            message.kind = "SlashCommand"
            message.argument = rawInput.command or ""
        elseif update.title == "Skill" then
            message.kind = "Skill"
            message.argument = rawInput.skill or "unknown skill"
            if rawInput.args then
                message.body = self:safe_split(rawInput.args)
            end
        else
            local ml = ClaudeUtils.mode_switch_label(update.title)
            if ml then
                message.kind = "switch_mode"
                message.argument = ml
            end
        end
    else
        message.argument = self:__ensure_command_string(rawInput.command)
            or ClaudeUtils.suppress_placeholder_title(update.title)
            or ""

        if not message.body then
            message.body = self:extract_content_body(update)
        end

        if kind == "search" then
            message.argument = ClaudeUtils.rewrite_grep_to_rg(message.argument)
            if rawInput.pattern then
                message.search_pattern = rawInput.pattern
            end
        elseif kind == "execute" then
            lift_execute_description(message, rawInput)
        end
    end
end

--- Build the edit diff from the standard ACP `content` diff entry.
---
--- Not from `rawInput`, even though every other field here comes from there.
--- claude-agent-acp streams tool input field-by-field and withholds `content`
--- from those partial updates on purpose: a diff built from partial input is
--- misleading (an Edit whose `new_string` has not arrived yet renders as a
--- pure deletion) or invalid (a Write without `content` has no `newText`).
--- The consolidated message carries the complete input and the diff together
--- moments later. Deriving the diff from `rawInput` bypasses that guard, and
--- MessageWriter freezes the first diff it renders, so the partial one is what
--- sticks — see acp-agent.js `streamedInputRefinement`.
---
--- `replace_all` still comes from `rawInput`: the content entry holds a single
--- old/new pair regardless of how many sites it applies to, and the renderer
--- needs the flag to match them all.
--- @protected
--- @param message agentic.ui.MessageWriter.ToolCallBase
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__apply_edit_diff(message, update)
    local diff_content = self:find_content_diff(update)
    if not diff_content then
        return
    end

    message.diff = {
        new = self:safe_split(diff_content.newText),
        old = self:safe_split(diff_content.oldText),
        all = (update.rawInput and update.rawInput.replace_all) or false,
    }
end

--- Reduce the Edit/Write PostToolUse-hook `tool_call_update` to the two facts
--- only it carries, or nil when `update` is not that notification.
---
--- The bridge registers a PostToolUse hook for Edit and Write and emits an
--- extra `tool_call_update` built from the tool response's `structuredPatch`
--- (`tools.js` `toolUpdateFromDiffToolResponse`). It carries no `status` and no
--- `rawInput`, so the shape-based guard in `__handle_tool_call_update` would
--- otherwise drop it.
---
--- Its `content[]` is deliberately ignored. `update_tool_call_block` merges
--- partials with `tbl_deep_extend("force", …)`, which merges list-valued
--- `diff.old` / `diff.new` element-by-element: a hook diff carrying context
--- lines would corrupt the tracker's diff data — and with it
--- `cached_diff_blocks` and the trust ranges — while the rendered diff stays
--- frozen at whatever was drawn first. Only the two scalar/flat fields below
--- are surfaced.
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase|nil
local function hook_patch_facts(update)
    local claude_meta = update._meta and update._meta.claudeCode
    local response = claude_meta and claude_meta.toolResponse
    local patch = response and response.structuredPatch
    -- Other notifications also carry `_meta.claudeCode.toolResponse` (mode
    -- switches, permission denials, subagent progress); a structuredPatch with
    -- no status is unique to the hook.
    if update.status or type(patch) ~= "table" then
        return nil
    end

    --- @type agentic.ui.MessageWriter.HunkRange[]
    local hunk_ranges = {}
    for _, hunk in ipairs(patch) do
        local start_line = hunk.newStart
        if type(start_line) == "number" then
            table.insert(hunk_ranges, {
                start_line = start_line,
                end_line = math.max(
                    start_line,
                    start_line + (hunk.newLines or 1) - 1
                ),
            })
        end
    end

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
        -- Exact, unlike inferring from an empty `diff.old`: Write reports
        -- whether it created the file, Edit never creates one.
        file_created = response.type == "create",
        hunk_ranges = hunk_ranges,
    }
    return message
end

--- Claude-agent-acp sends tool call updates without status, so we need to overload to handle it
--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__handle_tool_call_update(session_id, update)
    local patch_facts = hook_patch_facts(update)
    if patch_facts then
        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_tool_call_update(patch_facts)
        end)
        return
    end

    if
        not update.status
        and (not update.rawInput or vim.tbl_isempty(update.rawInput))
    then
        return
    end

    local message = self:__build_tool_call_update(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return ClaudeAgentACPAdapter
