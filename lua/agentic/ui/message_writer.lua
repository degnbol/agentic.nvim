local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Renderer = require("agentic.ui.tool_call_renderer")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")

local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")
--- Anchors a `*-fold` fence's opening line so a deferred close (chat window
--- hidden at write time) lands on the right row after later edits shift it.
local NS_FOLD_ANCHORS = vim.api.nvim_create_namespace("agentic_fold_anchors")
--- Per-turn token-usage footer (right-aligned virt_text on the turn-boundary
--- blank line). Own namespace so it stays out of the fold/tool clear paths;
--- footers are stamped once and never updated or cleared.
local NS_TURN_USAGE = vim.api.nvim_create_namespace("agentic_turn_usage")

--- Normalize an ACP-sourced kind value: strip whitespace, lowercase.
--- @param k string|nil
--- @return string
local function kind_key(k)
    if not k then
        return ""
    end
    return vim.trim(k):lower()
end

--- Synchronously materialise treesitter injections for a buffer row range.
--- The chat buffer's highlighter parses injections asynchronously under the
--- 'redrawtime' budget (see `:h vim.treesitter` / languagetree `_async_parse`),
--- yielding at 3ms steps. A heavy redraw can yield before reaching a block's
--- injected fence — e.g. an execute command's ```zsh — leaving it with only
--- the parent markup highlight until some unrelated later reparse. A
--- callback-less `parse(range)` runs to completion with no time budget, so the
--- injection child trees are created deterministically.
---
--- Called after every content `set_lines`, not just on a finalised block, so a
--- block that is rewritten mid-stream is re-highlighted with each version of
--- its content. After a `set_lines` the range is dirty, so this is a real
--- range-parse (one per block update); `parse` short-circuits only when the
--- range is already valid. Folds do not depend on this — `agentic.ui.folds`
--- reads the root tree only.
--- @param bufnr integer
--- @param start_row integer 0-indexed first row of the block
--- @param end_row integer 0-indexed last row of the block
local function materialize_injections(bufnr, start_row, end_row)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if ok and parser then
        parser:parse({ start_row, end_row })
    end
end

--- Tool call statuses that will not change again (safe to force a final parse).
--- @param status string|nil
--- @return boolean
local function is_final_status(status)
    return status == "completed" or status == "failed"
end

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"error"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)
--- @field block_col_hl? table<integer, string> Byte-col → language-qualified capture name from context-aware treesitter parse

--- @class agentic.ui.MessageWriter.SearchMatch
--- @field line_index integer Line index relative to block lines (0-based)
--- @field col_start integer Start column (byte offset)
--- @field col_end integer End column (byte offset)
--- @field hl_group? string Highlight group override (default: AgenticSearchMatch)

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean

--- An inclusive 1-based line range in a file's post-edit content.
--- @class agentic.ui.MessageWriter.HunkRange
--- @field start_line integer
--- @field end_line integer

--- @class agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id string
--- @field status agentic.acp.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field kind? agentic.acp.ToolKind
--- @field argument? string
--- @field search_pattern? string Regex pattern for highlighting matches in search output
--- @field read_range? { offset: integer, limit?: integer } Line range for partial reads
--- @field failure_reason? string[] Error message shown in place of kind-specific body when status == "failed" (e.g. hook-denial reason, tool error). Extracted from rawOutput, so no ``` fences.
--- @field description? string Model-provided one-line summary of the call (e.g. a Bash command's `description`), rendered as a title line under the header. Distinct from body (the output) and argument (the command).
--- @field file_created? boolean Whether the call created the file rather than changing existing content. Reported after the tool runs, so absent until then — a mutation with no value here has not been told either way, which is not the same as false.
--- @field hunk_ranges? agentic.ui.MessageWriter.HunkRange[] Post-edit line range of each changed hunk, as reported by the provider. Not rendered; recorded so the range survives a session restore, which re-deriving from disk cannot (the file is post-edit by then).

--- @class agentic.ui.MessageWriter.ToolCallBlock : agentic.ui.MessageWriter.ToolCallBase
--- @field kind agentic.acp.ToolKind
--- @field argument string
--- @field extmark_id? integer Range extmark spanning the block
--- @field decoration_extmark_ids? integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field search_matches? agentic.ui.MessageWriter.SearchMatch[] Pattern match positions (relative to block lines)
--- @field search_ansi? agentic.utils.Ansi.Span[][] ANSI highlight spans for search body
--- @field diff_tab? integer Tabpage ID of the diff preview tab (set by SessionManager)
--- @field cached_diff_blocks? agentic.ui.ToolCallDiff.DiffBlock[] Captured at render time so navigation (diff_jump) survives a later file refresh that breaks OLD-based matching
--- @field parent_tool_use_id? string Spawning Task tool id when this call belongs to a subagent; nil for main-agent calls
--- @field ordinal? integer Per-turn subagent ordinal (0-9, in spawn order); rendered as a sign only while numbering is active (see MessageWriter._numbering_active)

--- Append the closing fence for `lines` when they leave one open.
---
--- Prose and user prompts reach the chat buffer verbatim; only tool call blocks
--- get `safe_fence` protection. An unclosed ``` leaves `fenced_code_block`
--- unterminated, so it swallows the following prose and tool call blocks up to
--- the next bare ``` line, or to the end of the buffer — taking their
--- highlighting, and any `*-fold` fence opened inside it, with them. Closing it
--- bounds that to the block the model opened.
---
--- Only ever called at the end of a prose run: mid-stream the fence is
--- legitimately open and closing it early would corrupt the render.
--- @param lines string[]
local function close_fence(lines)
    local fence = TextWrap.unclosed_fence(lines)
    if fence then
        lines[#lines + 1] = fence
    end
end

--- Known prefix of the rejection boilerplate injected by the provider after
--- a permission denial. Streamed as agent_message_chunk but meant for the
--- model, not the user.
local REJECTION_PREFIX = "The user doesn't want to proceed"

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _last_message_type? string
--- @field _should_auto_scroll? boolean The frozen scroll verdict captured before a write. Consumed (and cleared) by whichever site executes the scroll: `_auto_scroll`'s callback on the non-fold path, `flush_pending_fold_ops` on the fold path. Never cleared on the callback's skip branch, so a verdict deferred to the fold-close (or to the BufWinEnter retry when no window exists yet) rides along with its pending fold.
--- @field _scroll_callback_queued? boolean Per-tick coalescing guard — true while a deferred scroll callback is queued this tick. Only prevents double-queuing; says nothing about whether the scroll happens.
--- @field _suppressing_rejection boolean When true, buffering chunks to detect rejection boilerplate
--- @field _rejection_buffer string Accumulated text while detecting rejection
--- @field _status_indicator? agentic.ui.StatusIndicator Reference for auto-scroll virt_lines awareness
--- @field _prose_anchor_line? integer 0-indexed buffer line of the first non-blank line of the current prose run; pinned at the top of the viewport during streaming and cleared on tool_call/separator/error so auto-scroll can resume
--- @field _suppress_pin_release? boolean True only while we are synchronously executing our own scroll commands or buffer writes; the WinScrolled autocmd checks this to distinguish our viewport changes from user-initiated ones
--- @field _auto_scroll_paused? boolean True after the user scrolled away from the bottom; gates pin-setting and auto-scroll until the user returns to the bottom (G or scroll-to-bottom). Survives turn boundaries — the user has to opt back in explicitly.
--- @field _pending_fold_ops { id: integer, open: boolean }[] Fold ops (anchor extmark id in NS_FOLD_ANCHORS + desired state) for `*-fold`/`-difffold` fences rendered while no chat window was visible. Flushed by the BufWinEnter autocmd when the chat window reappears. `open=false` closes (sidecars, rejected edits); `open=true` opens (applied edit diffs) — the explicit open both honours the diff's open-by-default and neutralises the foldexpr leak whereby a fold created after a closed one inherits the closed state.
--- @field _last_divider_line? integer Buffer line count as of the last `emit_divider`/`finalize_turn` write; `emit_divider` skips when the count is unchanged (nothing written since), so a no-content subagent gets no separator.
--- @field _pending_section_break? boolean Set by `_mark_section_break` when a block interrupts a prose run mid-turn (tool call, notice); makes the next prose chunk emit the empty `###` boundary that closes the interrupting section. Cleared by that chunk and at the turn boundary.
--- @field _numbering_active? boolean When true (set by `enable_numbering` once ≥2 subagents run concurrently in the turn), blocks carrying an `ordinal` render it as the sign on every body row (the whole left rail), replacing the │ border. Reset per turn.
local MessageWriter = {}
MessageWriter.__index = MessageWriter

--- Namespace for user-action marker extmarks: placed at write time on the
--- heading line of each user prompt (`write_user_prompt`) and each command
--- notice (`write_notice`). Drives both the row's identity sign and `[[`/`]]`
--- navigation, replacing the old text-scan on `line == "##"` (dead since the
--- heading became `## <first line>`). Global namespace + buffer-scoped marks is
--- sanctioned by .claude/rules/multi-tabpage.md (mirrors Renderer.NS_TOOL_BLOCKS).
MessageWriter.NS_USER_ACTIONS =
    vim.api.nvim_create_namespace("agentic_user_actions")

--- @param bufnr integer
--- @param status_indicator? agentic.ui.StatusIndicator
--- @return agentic.ui.MessageWriter
function MessageWriter:new(bufnr, status_indicator)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        tool_call_blocks = {},
        _last_message_type = nil,
        _should_auto_scroll = nil,
        _scroll_callback_queued = false,
        _chunk_start_line = nil,
        _pending_section_break = false,
        _suppressing_rejection = false,
        _rejection_buffer = "",
        _status_indicator = status_indicator,
        _prose_anchor_line = nil,
        _suppress_pin_release = false,
        _auto_scroll_paused = false,
        _pending_fold_ops = {},
        _last_divider_line = nil,
        _numbering_active = false,
    }, self)

    -- Listen for user scrolls. Our own programmatic scrolls and buffer
    -- writes also fire WinScrolled, but they run synchronously inside a
    -- `_suppress_pin_release` window so we ignore those. Vim is
    -- single-threaded — user input cannot interleave during a synchronous
    -- Lua chain — so the flag set/cleared around the writes/scrolls is
    -- race-free for distinguishing the two. The autocmd is buffer-scoped
    -- so it auto-cleans when the chat buffer is wiped.
    vim.api.nvim_create_autocmd("WinScrolled", {
        buffer = bufnr,
        callback = function()
            instance:on_user_scroll()
        end,
    })

    -- A fold rendered while the chat window was hidden never got its initial
    -- open/close (fold state is window-local). Apply those pending ops when
    -- the chat window reappears.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            instance:flush_pending_fold_ops()
        end,
    })

    return instance
end

--- True when the user has reached the bottom of the chat.
--- - When the chat window is focused, the user can move the cursor
---   freely; "at bottom" means the cursor is on the last line.
--- - When focus is elsewhere (input, todos, ...), the user can still
---   scroll the chat with the OS pointer hovering over it; the chat
---   cursor doesn't move, so "at bottom" means the chat viewport
---   reaches the last line (`botline`).
--- @param winid integer Chat window id
--- @return boolean
function MessageWriter:_is_at_bottom(winid)
    local total_lines = vim.api.nvim_buf_line_count(self.bufnr)
    if vim.api.nvim_get_current_win() == winid then
        local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
        return cursor_line >= total_lines
    end
    local info = vim.fn.getwininfo(winid)[1]
    return info ~= nil and info.botline >= total_lines
end

--- WinScrolled hook. Pauses or resumes auto-scroll based on whether the
--- cursor is at the bottom of the buffer. Public so the autocmd closure
--- can reach it without tripping LuaLS's invisible-field check.
---
--- - User scrolled away from bottom → pause auto-scroll, release any pin.
--- - User reached bottom (G or scroll-to-bottom) → resume.
---
--- Programmatic scrolls/writes are filtered out via `_suppress_pin_release`.
function MessageWriter:on_user_scroll()
    if self._suppress_pin_release then
        return
    end
    local wins = vim.fn.win_findbuf(self.bufnr)
    if #wins == 0 then
        return
    end

    if self:_is_at_bottom(wins[1]) then
        self._auto_scroll_paused = false
    else
        self._auto_scroll_paused = true
        self:_release_prose_pin()
    end
end

--- Start buffering the next message chunks to detect and suppress the
--- rejection boilerplate that the provider injects after permission denial.
function MessageWriter:suppress_next_rejection()
    self._suppressing_rejection = true
    self._rejection_buffer = ""
end

--- Drop the prose-pin anchor so the next auto-scroll falls back to the
--- normal scroll-to-bottom path. Called at turn boundaries (tool call,
--- separator, error, /new).
--- @private
function MessageWriter:_release_prose_pin()
    self._prose_anchor_line = nil
end

--- Make the next prose chunk of this turn open its own section, by emitting the
--- empty `###` boundary ahead of it (see `write_message_chunk`). Called by every
--- writer that interrupts a prose run mid-turn, so the flag has one setter.
--- @private
function MessageWriter:_mark_section_break()
    self._pending_section_break = true
end

--- Reset all per-turn mutable state. Called by refresh to unstick a
--- desynchronised display without restarting the session.
function MessageWriter:reset_turn_state()
    self._suppressing_rejection = false
    self._rejection_buffer = ""
    self._pending_section_break = false
    self._last_message_type = nil
    self._chunk_start_line = nil
    self._numbering_active = false
    self:_release_prose_pin()
end

--- Wraps BufHelpers.with_modifiable with scroll-suppression.
--- with_modifiable returns false for invalid buffers.
---
--- Buffer writes can incidentally shift topline (cursor at last line + buffer
--- growth past viewport, or set_lines on a tool call block above the prose
--- anchor pushing visible content). Those shifts fire WinScrolled, which
--- the autocmd would otherwise interpret as user intent and release the
--- prose pin. Suppress for the whole synchronous write — vim is
--- single-threaded so user input cannot interleave.
---
--- Every chat-buffer visual mutation routes through here, so this single
--- choke also forces the repaint neovim otherwise defers while a command-line
--- is open (see `BufHelpers.redraw_if_cmdline`), keeping streamed updates live
--- behind `:`. In every other mode that repaint is a no-op — the write lands
--- on screen at neovim's automatic pre-input redraw.
--- @param fn fun(bufnr: integer): boolean|nil
function MessageWriter:_with_modifiable_suppressed(fn)
    local prev_suppress = self._suppress_pin_release
    self._suppress_pin_release = true
    local result = BufHelpers.with_modifiable(self.bufnr, fn)
    self._suppress_pin_release = prev_suppress
    BufHelpers.redraw_if_cmdline()
    return result
end

--- Returns the text area width of the chat window (excluding sign column), or 80.
--- The chat window always has signcolumn=yes:1 (2 columns).
--- Clamped to `Config.windows.{min,max}_wrap_width` (either 0 disables that
--- bound). The floor wins against a narrow *window* — prose keeps wrapping at
--- `min_wrap_width` and is clipped at the window edge (the chat window is
--- `nowrap`) rather than being shredded into two-word lines — but never against
--- a configured `max_wrap_width`, which stays an absolute ceiling.
--- Returns 0 when the chat window has soft wrap enabled (no hard wrapping needed).
--- @return integer
function MessageWriter:_get_wrap_width()
    local winid = vim.fn.bufwinid(self.bufnr)
    if winid ~= -1 and vim.wo[winid].wrap then
        return 0
    end
    local width
    if winid ~= -1 then
        width = vim.api.nvim_win_get_width(winid) - 2
    else
        width = 80
    end
    local max = Config.windows.max_wrap_width
    local min = Config.windows.min_wrap_width
    if max > 0 then
        width = math.min(width, max)
        min = math.min(min, max)
    end
    if min > 0 then
        width = math.max(width, min)
    end
    return width
end

--- Writes a full message to the chat buffer and append two blank lines after.
--- Prose lines are hard-wrapped to the chat window width; code blocks are untouched.
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    local text = update.content
        and update.content.type == "text"
        and update.content.text --[[@as string]]

    if not text or text == "" then
        return
    end

    local lines = vim.split(text, "\n", { plain = true })
    close_fence(lines)
    lines = TextWrap.wrap_prose(lines, self:_get_wrap_width())

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function()
        self:_append_lines(lines)
        self:_append_lines({ "" })
    end)
end

--- Build the chat-buffer lines for a user prompt: the first line becomes the
--- `## ` heading (so treesitter-context pins it as the turn's breadcrumb),
--- remaining lines follow as body.
--- @param text string Raw prompt text
--- @return string[] lines
local function prompt_heading_lines(text)
    local prompt_lines = vim.split(text, "\n", { plain = true })
    local lines = { "## " .. prompt_lines[1] }
    for i = 2, #prompt_lines do
        table.insert(lines, prompt_lines[i])
    end
    return lines
end

--- Write a user prompt to the chat buffer and mark its heading line with a
--- prompt-marker extmark (drives the `❯` sign and `[[`/`]]` navigation).
--- Standalone rather than delegating to write_message: it owns the `---`
--- separator and needs the heading row post-append to place the marker.
--- @param text string Raw prompt text (first line becomes the `## ` heading)
--- @param extra_lines string[]|nil Display-only lines appended after the prompt
---        body (selected code / referenced files / diagnostics)
function MessageWriter:write_user_prompt(text, extra_lines)
    local lines = prompt_heading_lines(text)
    vim.list_extend(lines, extra_lines or {})

    local flat = vim.split(table.concat(lines, "\n"), "\n", { plain = true })
    -- Before the separator: a fence closed after it would swallow the `---`.
    close_fence(flat)
    vim.list_extend(flat, { "", "---", "" })
    flat = TextWrap.wrap_prose(flat, self:_get_wrap_width())

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function(bufnr)
        -- Flush pending prose reflow first. right_gravity=false survives
        -- appends but NOT a set_lines over the mark row, and prompt writes do
        -- not reset _chunk_start_line, so during replay (thought → prompt →
        -- thought) a later reflow range could span the heading and drag the
        -- marker. Mirrors the guard in write_tool_call_block.
        self:_reflow_chunks(bufnr, true)

        self:_append_lines(flat)
        self:_append_lines({ "" })

        -- Compute the heading row AFTER the append: on an empty buffer
        -- _append_lines replaces row 0 rather than appending, so a pre-capture
        -- would be off by one (session/load replay clears the buffer before
        -- the first chunk). The -1 accounts for the trailing blank just added.
        local heading_row = vim.api.nvim_buf_line_count(bufnr) - #flat - 1

        -- The sign rides on the marker itself, so there is no separate scan.
        vim.api.nvim_buf_set_extmark(
            bufnr,
            MessageWriter.NS_USER_ACTIONS,
            heading_row,
            0,
            {
                right_gravity = false,
                sign_text = "❯ ",
                sign_hl_group = "NonText",
            }
        )
    end)
end

--- @class agentic.ui.MessageWriter.Notice
--- @field glyph string Identity glyph for the command, stamped as the heading row's sign (see agentic.glyphs)
--- @field title string Heading text. Raw, not backtick-wrapped: an underscore or stray backtick in it can corrupt the heading through markdown inline parsing, the same exposure a user prompt's heading already carries.
--- @field body? string[] Already-formatted markdown lines placed under the heading
--- @field glyph_hl? string Highlight group for the sign; defaults to Theme's GLYPH
--- @field mid_turn? boolean True when a turn is running. Decides both the heading level and whether the notice closes the turn — see write_notice.

--- Write the result of a locally-handled command as a glyph-signed heading.
---
--- A notice records something the *user* did, so its row carries an identity
--- sign in the same channel as a prompt's `❯` and is navigable with `[[`/`]]`.
---
--- The heading level follows the notice's position in the section tree, which
--- `mid_turn` decides. Every command here takes effect the moment it is issued
--- (`/trust` widens permissions for the turn already running), so the honest
--- place to render it is where it happened:
---
--- - Between turns it is a sibling of the prompts: `##`, and it closes the turn.
--- - Mid-turn it must nest inside the running turn instead (`##` would close the
---   `## prompt` section and steal every following tool call as its child), so
---   it takes `###` and requests a section break for the prose that follows. It
---   must NOT finalize: that would reset the very cross-turn state the break
---   needs, and the break is what stops a later fenced code block from becoming
---   the notice's child — a `###` section holding a fence matches
---   `queries/agentic/context.scm` and would pin the breadcrumb for the rest of
---   the turn.
---
--- @param notice agentic.ui.MessageWriter.Notice
function MessageWriter:write_notice(notice)
    local level = notice.mid_turn and "###" or "##"
    local wrap_width = self:_get_wrap_width()
    -- Headings are never prose-wrapped (TextWrap.is_heading), so a long title
    -- would run off the window instead — truncate it as a tool-call head does.
    local heading = TextWrap.truncate_to_width(
        level .. " " .. notice.title,
        wrap_width > 0 and wrap_width or 80
    )

    local lines = { heading }
    vim.list_extend(lines, notice.body or {})
    table.insert(lines, "")

    -- A notice ends the prose run it interrupts: without this the viewport
    -- stays anchored to the pre-notice prose, since the re-pin check only
    -- fires once the anchor is nil.
    self:_release_prose_pin()
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function(bufnr)
        -- Flush pending prose reflow first, for the reason write_user_prompt
        -- documents: the heading would otherwise land inside an unclosed prose
        -- fence, and a later reflow's set_lines would span the heading row and
        -- drag the marker with it.
        self:_reflow_chunks(bufnr, true)

        self:_append_lines(lines)

        -- Computed AFTER the append: on an empty buffer _append_lines replaces
        -- row 0 rather than appending, so a pre-capture would be off by one.
        local heading_row = vim.api.nvim_buf_line_count(bufnr) - #lines

        vim.api.nvim_buf_set_extmark(
            bufnr,
            MessageWriter.NS_USER_ACTIONS,
            heading_row,
            0,
            {
                right_gravity = false,
                sign_text = notice.glyph .. " ",
                sign_hl_group = notice.glyph_hl or Theme.HL_GROUPS.GLYPH,
            }
        )
    end)

    if notice.mid_turn then
        self:_mark_section_break()
    else
        self:finalize_turn()
    end
end

--- Hints for known error classes. Keyed by both the Anthropic `error.type`
--- strings the embedded-JSON path produces and the internal classes the
--- errorKind map resolves to. authentication_error has no hint — re-auth is
--- handled by the caller (provider-specific re-auth flow).
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

--- Strip the bridge's `Internal error: ` / `API Error: NNN` wrapper prefix.
--- @param msg string
--- @return string stripped
local function strip_error_prefix(msg)
    msg = msg:gsub("^Internal error:%s*", "")
    msg = msg:gsub("^API Error:%s*%d+%s*", "")
    return msg
end

--- Parse a reset time like "5pm (Europe/London)" or "17:30 (Europe/London)"
--- into epoch seconds. Returns nil if parsing fails.
--- @param time_str string e.g. "5pm", "5:30pm", "17:00"
--- @param tz string e.g. "Europe/London"
--- @return number|nil epoch
local function parse_reset_time(time_str, tz)
    -- Use GNU date to parse the time in the given timezone
    local cmd =
        string.format("TZ=%s date -d 'today %s' +%%s 2>/dev/null", tz, time_str)
    local result = vim.fn.system(cmd)
    local epoch = tonumber(vim.trim(result))
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
--- Output: {"401 Invalid authentication credentials", "", "Try running /login ..."}
--- @param err agentic.acp.ACPError
--- @return string[] lines
--- @return string|nil error_type Error class (from errorKind if present, else text)
--- @return number|nil reset_epoch Epoch seconds when usage resets (for usage_limit errors)
local function format_error_lines(err)
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

            -- Build the main error line: "401 Invalid authentication credentials"
            -- or just the message if no HTTP code is available
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

    -- Detect usage limit errors: "You're out of extra usage · resets 5pm (Europe/London)"
    local time_str, tz = msg:match("resets%s+(%d+:?%d*%s*[ap]m)%s+%(([%w/]+)%)")
    if not time_str then
        -- Try 24h format: "resets 17:00 (Europe/London)"
        time_str, tz = msg:match("resets%s+(%d+:%d+)%s+%(([%w/]+)%)")
    end
    if time_str then
        vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
        local reset_epoch = parse_reset_time(time_str, tz)
        return lines, "usage_limit", reset_epoch
    end

    -- Fallback: just use the raw message, split on newlines
    vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
    return lines, nil
end

local HEADING = "### Error"
local HEADING_PREFIX_LEN = #"### "

--- Write an error message to the chat buffer with red error highlighting.
--- Uses `### Error` heading (same pattern as tool call headers) so markdown
--- treesitter renders the `###` as heading punctuation.
--- @param err agentic.acp.ACPError
--- @return string|nil error_type Error class for caller to dispatch on (errorKind-first)
--- @return number|nil reset_epoch Epoch seconds when usage resets (for usage_limit errors)
function MessageWriter:write_error_message(err)
    local body_lines, error_type, reset_epoch = format_error_lines(err)
    local all_lines = { HEADING, "" }
    vim.list_extend(all_lines, body_lines)

    self:_release_prose_pin()
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function(bufnr)
        -- An error ends the prose run. Without the flush the error block lands
        -- inside a fence the interrupted prose left open, and finalize_turn's
        -- reflow would later span it and move its NS_ERROR extmarks.
        self:_reflow_chunks(bufnr, true)

        local was_empty = BufHelpers.is_buffer_empty(bufnr)
        self:_append_lines(all_lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1
        local start_row = end_row - #all_lines + 1
        -- When the buffer was empty, _append_lines replaces instead of
        -- appending, so the heading is at row 0.
        if was_empty then
            start_row = 0
        end

        -- Highlight "Error" portion of "### Error" (after "### ")
        vim.api.nvim_buf_set_extmark(
            bufnr,
            NS_ERROR,
            start_row,
            HEADING_PREFIX_LEN,
            {
                end_col = #HEADING,
                hl_group = Theme.HL_GROUPS.ERROR_HEADING,
                priority = 200,
            }
        )

        -- Highlight body lines (skip the blank separator at start_row + 1)
        for i = start_row + 2, end_row do
            local line = vim.api.nvim_buf_get_lines(bufnr, i, i + 1, false)[1]
            if line and line ~= "" then
                vim.api.nvim_buf_set_extmark(bufnr, NS_ERROR, i, 0, {
                    end_col = #line,
                    hl_group = Theme.HL_GROUPS.ERROR_BODY,
                })
            end
        end

        self:_append_lines({ "" })
    end)

    return error_type, reset_epoch
end

--- Write an action hint line after an error, styled with ERROR_BODY highlight.
--- @param text string The action hint text (e.g. "Press [r] to re-authenticate")
function MessageWriter:write_error_action(text)
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function(bufnr)
        self:_append_lines({ text, "" })

        local row = vim.api.nvim_buf_line_count(bufnr) - 2
        vim.api.nvim_buf_set_extmark(bufnr, NS_ERROR, row, 0, {
            end_col = #text,
            hl_group = Theme.HL_GROUPS.ERROR_BODY,
        })
    end)
end

--- Close out a turn: reset all per-turn state, reflow any streamed prose, and
--- append a trailing blank line.
function MessageWriter:finalize_turn()
    -- Reset ALL per-turn state at the turn boundary. Any flag that was set
    -- during the turn must be cleared here, otherwise it silently corrupts
    -- subsequent turns (the "stuck 1 message behind" family of bugs).
    self._suppressing_rejection = false
    self._rejection_buffer = ""
    self._pending_section_break = false
    self._last_message_type = nil
    self._numbering_active = false
    self:_release_prose_pin()

    self:_with_modifiable_suppressed(function(bufnr)
        self:_reflow_chunks(bufnr, true)
        self:_append_lines({ "" })
    end)
    self._last_divider_line = vim.api.nvim_buf_line_count(self.bufnr)
end

--- Append a `---` separator to mark the end of one subagent's detour in the
--- subagents buffer. No-op if nothing was written since the last separator (a
--- Task that streamed no interim content gets none). Unlike `finalize_turn`
--- this touches no cross-turn state, so it is safe to call mid-turn — the
--- subagent lifecycle fires it per Task as each one closes.
function MessageWriter:emit_divider()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end
    if vim.api.nvim_buf_line_count(self.bufnr) == self._last_divider_line then
        return
    end
    self:_with_modifiable_suppressed(function(bufnr)
        self:_reflow_chunks(bufnr, true)
        self:_append_lines({ "", "---", "" })
    end)
    self._last_divider_line = vim.api.nvim_buf_line_count(self.bufnr)
end

--- The 2-cell sign to stamp on a block's body rows in place of the │ border, or
--- nil to leave the plain border. A number shows only while numbering is active on
--- this writer (`enable_numbering`, once ≥2 subagents run concurrently) and the
--- block carries an ordinal in the single-digit range the sign column holds.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
--- @return string|nil
function MessageWriter:_ordinal_sign(block)
    local n = block.ordinal
    if not self._numbering_active or not n or n > 9 then
        return nil
    end
    return tostring(n) .. " "
end

--- Activate subagent ordinal numbering and backfill the number onto every
--- already-rendered block that carries an ordinal. Called when a second
--- subagent begins running concurrently in the turn (see SessionManager's
--- latch); before that a lone subagent's blocks show no number. Idempotent.
function MessageWriter:enable_numbering()
    if self._numbering_active then
        return
    end
    self._numbering_active = true
    for _, block in pairs(self.tool_call_blocks) do
        self:_stamp_ordinal(block)
    end
end

--- @private
--- Restamp a block's whole body rail to its ordinal, in place (reusing the
--- decoration extmark ids). No-op for a block with no ordinal or a dropped range
--- extmark. The range extmark spans header (start_row) to footer (end_row); body
--- rows are the rows between. The decoration ids run
--- `[header, body_1 .. body_n, footer, (dim?)]`, front-indexed by buffer offset,
--- so the id for buffer row `r` is `ids[r - start_row + 1]`; header (start_row)
--- and footer (end_row) keep their corner signs, every body row in between takes
--- the digit. Concealed fence-delimiter rows get it too but stay zero-height at
--- conceallevel=2, so it does not show there.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_stamp_ordinal(block)
    local sign = self:_ordinal_sign(block)
    local ids = block.decoration_extmark_ids
    if not sign or not block.extmark_id or not ids then
        return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        Renderer.NS_TOOL_BLOCKS,
        block.extmark_id,
        { details = true }
    )
    local start_row, details = pos[1], pos[3]
    if not start_row or not details or not details.end_row then
        return
    end
    for row = start_row + 1, details.end_row - 1 do
        local id = ids[row - start_row + 1]
        if id then
            Renderer.restamp_border(self.bufnr, id, row, sign)
        end
    end
end

--- Stamp the per-turn token-usage footer on the trailing blank line that
--- `finalize_turn` just appended: dim, right-aligned virt_text like
--- `1.2k in · 0.4k out`. No-ops on missing or all-zero usage (stalls, cancels,
--- and silent upstream auth failures emit zeros — a "0" would mislead).
--- @param usage { inputTokens?: number, outputTokens?: number }|nil
function MessageWriter:set_turn_usage(usage)
    if type(usage) ~= "table" then
        return
    end
    local input = usage.inputTokens or 0
    local output = usage.outputTokens or 0
    if input == 0 and output == 0 then
        return
    end

    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local text =
        string.format("%.1fk in · %.1fk out", input / 1000, output / 1000)
    local last_row = vim.api.nvim_buf_line_count(self.bufnr) - 1
    vim.api.nvim_buf_set_extmark(self.bufnr, NS_TURN_USAGE, last_row, 0, {
        virt_text = { { text, Theme.HL_GROUPS.TURN_USAGE } },
        virt_text_pos = "right_align",
    })
end

--- Reflow prose in the region written by write_message_chunk.
--- When `flush_all` is false (during streaming), only reflows complete
--- paragraphs — up to the last blank line, leaving the in-progress
--- paragraph untouched. When true (response finished), reflows everything.
---
--- `flush_all` is also the end of the prose run (the callers are the turn
--- boundary, a tool call, a prompt, an error and a divider), so it closes an
--- unclosed fence — see `close_fence`. The streaming path keeps `_chunk_start_line`
--- outside any open fence so that check sees the opener; a marker parked inside
--- a fence would also make `wrap_prose` hard-wrap code as prose, since it starts
--- each region assuming it is not in one.
--- @param bufnr integer
--- @param flush_all? boolean
function MessageWriter:_reflow_chunks(bufnr, flush_all)
    local start = self._chunk_start_line
    if not start then
        return
    end

    local buf_end = vim.api.nvim_buf_line_count(bufnr)
    if start >= buf_end then
        -- Nothing to reflow, but still clear the marker on flush so the
        -- next turn recalculates from scratch. Without this, the stale
        -- _chunk_start_line carries over and corrupts the next turn's reflow.
        if flush_all then
            self._chunk_start_line = nil
        end
        return
    end

    local reflow_end = buf_end -- 0-indexed exclusive

    if not flush_all then
        -- Find the last blank line in the range (excluding the final line
        -- which is still being appended to). Reflow up to and including it.
        local last_blank = nil
        local lines = vim.api.nvim_buf_get_lines(bufnr, start, buf_end, false)
        for i = #lines - 1, 1, -1 do -- skip last line (index #lines)
            if lines[i]:match("^%s*$") then
                last_blank = start + (i - 1) -- lines[1] = buffer line `start`
                break
            end
        end
        if not last_blank then
            return -- no complete paragraph yet
        end
        reflow_end = last_blank + 1 -- exclusive, include the blank line

        -- Stop short of an open fence: blank lines inside a code block would
        -- otherwise advance the marker into it.
        local _, opener = TextWrap.unclosed_fence(
            vim.list_slice(lines, 1, reflow_end - start)
        )
        if opener then
            reflow_end = start + opener - 1
            if reflow_end <= start then
                return
            end
        end
    end

    local raw = vim.api.nvim_buf_get_lines(bufnr, start, reflow_end, false)
    local wrapped = TextWrap.wrap_prose(raw, self:_get_wrap_width())

    if not vim.deep_equal(raw, wrapped) then
        vim.api.nvim_buf_set_lines(bufnr, start, reflow_end, false, wrapped)
    end

    if flush_all then
        -- Same job as `close_fence`, but appended to the buffer: reflow_end is
        -- the end of the buffer here, and extending `wrapped` would also extend
        -- `raw`, which wrap_prose returns unchanged when the window soft-wraps.
        local fence = TextWrap.unclosed_fence(wrapped)
        if fence then
            self:_append_lines({ fence })
        end
        self._chunk_start_line = nil
    else
        -- Advance past the reflowed region
        self._chunk_start_line = start + #wrapped
    end
end

--- Appends message chunks to the last line and column in the chat buffer
--- Some ACP providers stream chunks instead of full messages
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message_chunk(update)
    -- Thought chunks flow through as prose. _on_session_update routes them to
    -- the writer for the agent that produced them (main → chat, subagent →
    -- subagents window), so each window shows its own agent's thinking.
    local text = update.content
        and update.content.type == "text"
        and update.content.text --[[@as string]]

    if not text or text == "" then
        return
    end

    -- After a permission rejection, the provider streams boilerplate
    -- instructions meant for the model ("The user doesn't want to proceed…").
    -- Buffer incoming chunks and check for the known prefix. Once we have
    -- enough text: if it matches, suppress the whole paragraph; if not, flush
    -- the buffer and continue rendering normally.
    if self._suppressing_rejection then
        self._rejection_buffer = self._rejection_buffer .. text
        local buf = self._rejection_buffer

        -- Still accumulating — not enough text to decide yet
        if #buf < #REJECTION_PREFIX then
            -- Check that what we have so far could still match
            if REJECTION_PREFIX:sub(1, #buf) == buf then
                return
            end
            -- Mismatch — not rejection text, flush below
        elseif buf:sub(1, #REJECTION_PREFIX) == REJECTION_PREFIX then
            -- Confirmed rejection boilerplate — suppress entirely.
            -- Keep _suppressing_rejection true to drop remaining chunks
            -- of this paragraph. Reset on next tool call via
            -- write_tool_call_block.
            return
        end

        -- Not rejection text — stop suppressing and flush the buffer
        self._suppressing_rejection = false
        text = self._rejection_buffer
        self._rejection_buffer = ""
    end

    if
        self._last_message_type == "agent_thought_chunk"
        and update.sessionUpdate == "agent_message_chunk"
    then
        -- Different message type, add newline before appending, to create visual separation
        -- only for thought -> message
        text = "\n\n" .. text
    end

    -- Prose that resumes after an interrupting block must close that block's
    -- section so treesitter-context stops pinning its heading (a tool call's
    -- filename, a notice's title) while the user reads the summary. Emit an
    -- empty `###` heading (no inline child, so context.scm never captures it)
    -- ahead of the prose, plus the blank line for visual breathing room. Once
    -- per prose run — the flag resets after the first chunk.
    if self._pending_section_break then
        text = "\n###\n\n" .. text
        self._pending_section_break = false
    end

    self._last_message_type = update.sessionUpdate

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function(bufnr)
        local last_line = vim.api.nvim_buf_line_count(bufnr) - 1

        -- Record where streamed content starts (0-indexed)
        if not self._chunk_start_line then
            local current = vim.api.nvim_buf_get_lines(
                bufnr,
                last_line,
                last_line + 1,
                false
            )[1] or ""
            -- If appending to a non-empty line, this line is the start
            -- If the line is empty, the new content starts here
            self._chunk_start_line = current == "" and last_line or last_line
        end

        local current_line = vim.api.nvim_buf_get_lines(
            bufnr,
            last_line,
            last_line + 1,
            false
        )[1] or ""
        local start_col = #current_line

        -- Guard against two messages being concatenated with no whitespace
        -- (e.g. auto-compaction text followed by resumed response). Normal
        -- streaming tokens include leading whitespace at word boundaries, so
        -- an uppercase letter directly after a lowercase letter, digit, or
        -- sentence-ending punctuation means the provider spliced two separate
        -- messages together. Uppercase after uppercase is left alone to avoid
        -- splitting abbreviations like "CWD" streamed as "C" + "WD".
        if
            start_col > 0
            and current_line:sub(-1):match("[%l%d%.%!%?%)\"']")
            and text:sub(1, 1):match("%u")
        then
            text = " " .. text
        end

        local lines_to_write = vim.split(text, "\n", { plain = true })

        local success, err = pcall(
            vim.api.nvim_buf_set_text,
            bufnr,
            last_line,
            start_col,
            last_line,
            start_col,
            lines_to_write
        )

        if not success then
            Logger.notify(
                "Failed to write message chunk:\n" .. tostring(err),
                vim.log.levels.ERROR,
                { title = "Agentic buffer write error" }
            )
        end

        -- Pin the start of the current prose run to the top of the viewport
        -- once non-blank content lands. The line we wrote on can begin with a
        -- "\n" prefix (added when prose follows a tool call), so scan forward
        -- a few lines from chunk_start_line to skip the leading blank.
        -- Skip when the user has paused auto-scroll: pinning would require
        -- scrolling the view, which is exactly what the user opted out of.
        if self._prose_anchor_line == nil and not self._auto_scroll_paused then
            local total = vim.api.nvim_buf_line_count(bufnr)
            local scan_end = math.min(self._chunk_start_line + 4, total - 1)
            for line = self._chunk_start_line, scan_end do
                local content =
                    vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
                -- Skip the leading blank and the empty `###` section boundary
                -- inserted before a post-tool-call prose run; pin real prose.
                if
                    content
                    and content:match("%S")
                    and not content:match("^#+%s*$")
                then
                    self._prose_anchor_line = line
                    break
                end
            end
        end

        -- Wrap the last line immediately if it overflows, so the user sees
        -- wrapping during streaming instead of after the line completes.
        -- Skip when wrap_width is 0 (soft wrap enabled on the window).
        local wrap_width = self:_get_wrap_width()
        local end_line = vim.api.nvim_buf_line_count(bufnr) - 1
        local tail = vim.api.nvim_buf_get_lines(
            bufnr,
            end_line,
            end_line + 1,
            false
        )[1] or ""
        if wrap_width > 0 and #tail > wrap_width then
            local wrapped = TextWrap.wrap_single_line(tail, wrap_width)
            if #wrapped > 1 then
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    end_line,
                    end_line + 1,
                    false,
                    wrapped
                )
            end
        end

        -- Reflow complete paragraphs when a paragraph boundary was written
        if text:find("\n") then
            self:_reflow_chunks(bufnr)
        end
    end)
end

--- @param lines string[]
--- @return nil
function MessageWriter:_append_lines(lines)
    local start_line = BufHelpers.is_buffer_empty(self.bufnr) and 0 or -1

    local success, err = pcall(
        vim.api.nvim_buf_set_lines,
        self.bufnr,
        start_line,
        -1,
        false,
        lines
    )

    if not success then
        Logger.notify(
            "Failed to append lines to buffer:\n" .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic buffer write error" }
        )
    end
end

--- @param bufnr integer
--- @return boolean
function MessageWriter:_check_auto_scroll(bufnr)
    -- The user explicitly disabled auto-scroll by scrolling away from the
    -- bottom. They re-enable it by going back to the bottom (G or
    -- scroll-to-bottom), which `on_user_scroll` detects and clears.
    if self._auto_scroll_paused then
        return false
    end

    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return true
    end
    local winid = wins[1]

    -- During an active prose pin the cursor is parked inside the clamped
    -- viewport, far from the buffer end, so the at-bottom check below
    -- would always fail and stop auto-scroll. Override while the pin is
    -- set — a user scroll would have cleared `_auto_scroll_paused` and
    -- released the pin already, so reaching here means the pin is ours.
    if self._prose_anchor_line then
        return true
    end

    return self:_is_at_bottom(winid)
end

--- Whether the cursor is at the bottom of the chat buffer.
--- @return boolean
function MessageWriter:is_near_bottom()
    return self:_check_auto_scroll(self.bufnr)
end

--- Scroll the chat window to the bottom if the cursor is at the end.
--- Same gate as streaming auto-scroll so users reading earlier content
--- are not interrupted.
function MessageWriter:scroll_to_bottom()
    if not self:_check_auto_scroll(self.bufnr) then
        return
    end

    local wins = vim.fn.win_findbuf(self.bufnr)
    if #wins == 0 then
        return
    end

    BufHelpers.scroll_down(wins[1])
end

--- Execute a scroll-to-bottom now: compute the prose-pin cap and scroll,
--- wrapped in `_suppress_pin_release` so the synchronous WinScrolled from
--- winrestview isn't mistaken for a user scroll. The flag is saved and
--- restored (not hardcoded back to false) so this nests inside
--- `flush_pending_fold_ops`'s own suppress wrap. Pure mechanics — callers
--- own the gating (the captured verdict + the live `_auto_scroll_paused`).
--- @param bufnr integer Buffer number to scroll
function MessageWriter:_scroll_now(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return
    end

    -- topline is 1-indexed; _prose_anchor_line is 0-indexed.
    local pause = Config.auto_scroll
        and Config.auto_scroll.pause_on_prose ~= false
    local max_topline = (pause and self._prose_anchor_line)
            and (self._prose_anchor_line + 1)
        or nil

    local prev_suppress = self._suppress_pin_release
    self._suppress_pin_release = true
    BufHelpers.scroll_down(wins[1], max_topline)
    self._suppress_pin_release = prev_suppress
end

--- Capture at-bottom / pin state, then schedule a scroll-to-bottom after
--- the current synchronous write. Must be called **before** the write —
--- a post-write check would see `botline < total_lines` (the write just
--- grew the buffer past the viewport) and gate the scroll off.
--- Coalesces multiple calls per tick via `_scroll_callback_queued`.
---
--- When the write queued a fold op, the scroll is owned by
--- `flush_pending_fold_ops` instead: that runs strictly after treesitter's
--- fold-level recompute, so it measures the already-*closed* fold. Scrolling
--- here would race the recompute and park the viewport at the unfolded bottom
--- (the fold-vs-auto-scroll timing bug). The callback skips when fold ops are
--- pending, leaving the verdict for flush to consume.
--- @param bufnr integer Buffer number to scroll
function MessageWriter:_auto_scroll(bufnr)
    if self._should_auto_scroll ~= true then
        self._should_auto_scroll = self:_check_auto_scroll(bufnr)
    end

    if self._scroll_callback_queued then
        return
    end
    self._scroll_callback_queued = true

    vim.schedule(function()
        self._scroll_callback_queued = false

        -- Fold-close owns the scroll on this tick — leave the verdict for it.
        if #self._pending_fold_ops > 0 then
            return
        end

        if
            vim.api.nvim_buf_is_valid(bufnr)
            and self._should_auto_scroll
            and not self._auto_scroll_paused
        then
            self:_scroll_now(bufnr)
        end

        self._should_auto_scroll = nil
    end)
end

--- Find the first valid window currently displaying the chat buffer. Fold
--- state is window-local, so closing a fold requires a window.
--- @return integer|nil winid
function MessageWriter:_chat_window()
    for _, win in ipairs(vim.fn.win_findbuf(self.bufnr)) do
        if vim.api.nvim_win_is_valid(win) then
            return win
        end
    end
    return nil
end

--- Queue an open/close of the treesitter fold containing `anchor_row`.
--- `anchor_row` is the first body line of a `*-fold`/`-difffold` block — a
--- level-1 row that belongs only to our fold (the fold spans
--- `code_fence_content`, so the concealed fence delimiters are level 0,
--- outside it). The one-level :foldopen/:foldclose hits exactly our block,
--- leaving other blocks untouched. Anchoring on a body line (not the
--- delimiter) also keeps a closed fold's first screen row visible, so the
--- `··· N lines ···` foldtext shows.
---
--- An anchor extmark tracks the row across later edits, and the op is deferred
--- so it can wait for a chat window: with none visible the anchor stays pending
--- until BufWinEnter.
--- @param anchor_row integer 0-indexed buffer row of the block's first body line
--- @param open boolean Desired state — true opens the fold, false closes it
function MessageWriter:_queue_fold(anchor_row, open)
    local id = vim.api.nvim_buf_set_extmark(
        self.bufnr,
        NS_FOLD_ANCHORS,
        anchor_row,
        0,
        {}
    )
    table.insert(self._pending_fold_ops, { id = id, open = open })
    vim.schedule(function()
        self:flush_pending_fold_ops()
    end)
end

--- See _queue_fold.
--- @param anchor_row integer
function MessageWriter:_close_fold(anchor_row)
    self:_queue_fold(anchor_row, false)
end

--- Open the fold containing `anchor_row`. Edit diffs are foldable but render
--- open; an explicit open is required because a fold created after a closed
--- one inherits the closed state under foldmethod=expr (the foldexpr leak), so
--- relying on the foldlevel default would leave applied edits collapsed after
--- any earlier close (a long execute body, a rejected edit). See _queue_fold.
--- @param anchor_row integer
function MessageWriter:_open_fold(anchor_row)
    self:_queue_fold(anchor_row, true)
end

--- Apply every pending fold op (see _queue_fold). Resolves each anchor
--- extmark's current row so edits since the render are accounted for. No-op
--- when nothing is pending. When no chat window exists yet the anchors stay
--- pending so the BufWinEnter autocmd retries once the window reappears.
--- Ops are wrapped in `_suppress_pin_release` so the viewport shift from
--- collapsing/expanding a fold is not mistaken for a user scroll.
--- Public so the BufWinEnter autocmd closure can reach it without tripping
--- LuaLS's invisible-field check.
function MessageWriter:flush_pending_fold_ops()
    if #self._pending_fold_ops == 0 then
        return
    end
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        self._pending_fold_ops = {}
        return
    end
    local win = self:_chat_window()
    if not win then
        return
    end

    local prev_suppress = self._suppress_pin_release
    self._suppress_pin_release = true
    for _, op in ipairs(self._pending_fold_ops) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(
            self.bufnr,
            NS_FOLD_ANCHORS,
            op.id,
            {}
        )
        if pos[1] then
            -- A missing fold (E490) is non-fatal — the body just stays
            -- visible — so it is swallowed deliberately. The live cause is
            -- insert mode: vim suppresses foldUpdate there, so a block
            -- finishing while the user types in the prompt buffer finds no
            -- fold to close. Core retries such ops on InsertLeave
            -- (`_fold.lua`); this flush does not, so the body stays expanded.
            pcall(vim.api.nvim_win_call, win, function()
                vim.cmd(
                    string.format(
                        "%d%s",
                        pos[1] + 1,
                        op.open and "foldopen" or "foldclose"
                    )
                )
            end)
        end
        pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NS_FOLD_ANCHORS, op.id)
    end
    self._suppress_pin_release = prev_suppress
    self._pending_fold_ops = {}

    -- The fold path's single scroll. The folds are now closed, so the
    -- fold-aware scroll_down measures the collapsed height — `_auto_scroll`'s
    -- callback skipped while these ops were pending and deferred to here.
    -- Gate on the captured verdict and the live pause toggle (the verdict
    -- could have deferred as far as the BufWinEnter retry — a wide gap for the
    -- user to scroll away). Both are needed: the verdict freezes the pre-write
    -- at-bottom snapshot, the toggle catches a scroll-away during the gap.
    if self._should_auto_scroll and not self._auto_scroll_paused then
        self:_scroll_now(self.bufnr)
    end
    self._should_auto_scroll = nil
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    -- A new tool call means any rejection boilerplate is over
    if self._suppressing_rejection then
        self._suppressing_rejection = false
        self._rejection_buffer = ""
    end

    -- A tool call ends the current prose run, so auto-scroll resumes.
    self:_release_prose_pin()

    -- Mode-switch tool calls (EnterPlanMode, ExitPlanMode, EnterWorktree)
    -- carry internal instructions in their body — strip it so only the
    -- compact header renders (e.g. "Switch Mode `EnterPlanMode`").
    -- TodoWrite body is the raw JSON request — hide it since the todo window
    -- shows the rendered todos.
    if
        kind_key(tool_call_block.kind) == "switch_mode"
        or kind_key(tool_call_block.kind) == "todowrite"
    then
        tool_call_block.body = nil
    end

    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function(bufnr)
        -- Flush any pending prose reflow before writing the tool call block.
        -- Without this, finalize_turn's _reflow_chunks would later process
        -- a range that includes these tool call lines, destroying extmarks
        -- (decorations, status, range tracking) via nvim_buf_set_lines.
        self:_reflow_chunks(bufnr, true)

        local kind = tool_call_block.kind

        local lines, highlight_ranges, ansi_highlights, fold_anchor, dim_range, fold_open =
            Renderer.prepare_block_lines(
                tool_call_block,
                self:_get_wrap_width()
            )

        self:_append_lines(lines)

        -- Compute start/end AFTER _append_lines: when the buffer was empty,
        -- _append_lines replaces instead of appending, so line_count before
        -- the call would over-count by 1.
        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1
        local start_row = end_row - #lines + 1

        Renderer.apply_block_highlights(
            bufnr,
            start_row,
            end_row,
            kind,
            highlight_ranges,
            ansi_highlights,
            tool_call_block.search_matches,
            tool_call_block.search_ansi
        )

        tool_call_block.decoration_extmark_ids = Renderer.render_decorations(
            bufnr,
            start_row,
            end_row,
            self:_ordinal_sign(tool_call_block)
        )

        -- Gated to final render (unlike materialize_injections below, which is
        -- now unconditional). The block is torn down and rebuilt on every
        -- streaming set_lines, so an ungated fold op re-fires each render only
        -- to be redone — pure churn. Deferring both open and close to
        -- completion applies fold state once, when the block is stable, and
        -- removes the mid-stream :foldclose that is the suspected seed for the
        -- foldexpr leak (see _open_fold).
        if fold_anchor and is_final_status(tool_call_block.status) then
            if fold_open then
                self:_open_fold(start_row + fold_anchor)
            else
                self:_close_fold(start_row + fold_anchor)
            end
        end
        if dim_range then
            local dim_id = Renderer.set_dim_range(
                bufnr,
                start_row + dim_range[1],
                start_row + dim_range[2]
            )
            table.insert(tool_call_block.decoration_extmark_ids, dim_id)
        end

        -- right_gravity=true so the start moves past content inserted
        -- at the boundary by a preceding block's update_tool_call_block.
        -- set_lines(buf, prev_start, prev_end+1) has its exclusive end
        -- at this block's start row — right_gravity=false would pull the
        -- start into the replacement range, corrupting this extmark.
        tool_call_block.extmark_id = vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            start_row,
            0,
            {
                end_row = end_row,
                right_gravity = true,
                end_right_gravity = false,
            }
        )

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        Renderer.apply_status_footer(bufnr, end_row, tool_call_block.status)

        materialize_injections(bufnr, start_row, end_row)

        self:_append_lines({ "" })
        self:_mark_section_break()
    end)
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBase
function MessageWriter:update_tool_call_block(tool_call_block)
    local tracker = self.tool_call_blocks[tool_call_block.tool_call_id]

    if not tracker then
        Logger.notify(
            "Tool call update for unknown block: "
                .. tostring(tool_call_block.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: missing tracker" }
        )
        return
    end

    -- Strip internal instructions from switch_mode updates
    -- TodoWrite body is the raw JSON request — hide it since the todo window
    -- shows the rendered todos.
    if
        kind_key(tracker.kind) == "switch_mode"
        or kind_key(tracker.kind) == "todowrite"
    then
        tool_call_block.body = nil
    end

    -- For read blocks, extract range from the current argument before the merge
    -- overwrites it — the initial title may contain "(N - M)" that the adapter
    -- update replaces with just the file path.
    if kind_key(tracker.kind) == "read" and not tracker.read_range then
        local _, range = Renderer.parse_read_range(tracker.argument)
        if range then
            tracker.read_range = range
        end
    end

    -- Some ACP providers don't send the diff on the first tool_call
    local already_has_diff = tracker.diff ~= nil
    local previous_body = tracker.body

    tracker = vim.tbl_deep_extend("force", tracker, tool_call_block)

    -- Merge body: append new to previous with divider if both exist and are different
    if
        previous_body
        and tool_call_block.body
        and not vim.deep_equal(previous_body, tool_call_block.body)
    then
        local merged = vim.list_extend({}, previous_body)
        vim.list_extend(merged, { "", "---", "" })
        vim.list_extend(merged, tool_call_block.body)
        tracker.body = merged
    end

    self.tool_call_blocks[tool_call_block.tool_call_id] = tracker

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        Renderer.NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.notify(
            "Tool call extmark lost: " .. tostring(tracker.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: extmark lost" }
        )
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.notify(
            "Tool call extmark has no end_row: "
                .. tostring(tracker.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: extmark corrupt" }
        )
        return
    end

    if start_row >= old_end_row then
        Logger.debug_to_file(
            "COLLAPSED EXTMARK — tool call block range is degenerate, bailing out",
            {
                tool_call_id = tracker.tool_call_id,
                kind = tracker.kind,
                argument = tracker.argument,
                start_row = start_row,
                old_end_row = old_end_row,
                status = tool_call_block.status,
                already_has_diff = already_has_diff,
                line_count = vim.api.nvim_buf_line_count(self.bufnr),
            }
        )
        -- Remove from tracking — the block is corrupt and cannot be updated
        self.tool_call_blocks[tool_call_block.tool_call_id] = nil
        return
    end

    -- Capture at-bottom state before the write. nvim_buf_set_lines below can
    -- grow the block by many lines; a post-write check would see
    -- botline < total_lines and gate the scroll off.
    self:_auto_scroll(self.bufnr)

    self:_with_modifiable_suppressed(function(bufnr)
        -- Diff blocks don't change after the initial render
        -- only update status highlights - don't replace content.
        -- Exception: the transition to `failed` re-renders so the failure
        -- reason renders below the diff and the diff folds closed
        -- (tool_call_renderer diff branch). Re-extraction is safe — a failed
        -- file-mutating tool never applied its change, so the file is
        -- unchanged and reproduces the same diff.
        if already_has_diff and tracker.status ~= "failed" then
            if old_end_row > vim.api.nvim_buf_line_count(bufnr) then
                Logger.notify(
                    string.format(
                        "Tool call footer out of bounds: row %d, buf has %d lines",
                        old_end_row,
                        vim.api.nvim_buf_line_count(bufnr)
                    ),
                    vim.log.levels.WARN,
                    { title = "Agentic sync: footer OOB" }
                )
                return false
            end

            -- Decorations (╭│╰ borders) are stable — leave them in place.
            -- Only refresh status footer which changes on completion.
            Renderer.apply_status_footer(bufnr, old_end_row, tracker.status)

            return false
        end

        local new_lines, highlight_ranges, ansi_highlights, fold_anchor, dim_range, fold_open =
            Renderer.prepare_block_lines(tracker, self:_get_wrap_width())

        -- Compare content lines excluding the footer — the buffer's footer
        -- has status text while prepare_block_lines produces "" for it.
        local current_lines =
            vim.api.nvim_buf_get_lines(bufnr, start_row, old_end_row + 1, false)
        local content_unchanged = #new_lines == #current_lines
        if content_unchanged then
            for i = 1, #new_lines - 1 do
                if new_lines[i] ~= current_lines[i] then
                    content_unchanged = false
                    break
                end
            end
        end

        if content_unchanged then
            Renderer.apply_status_footer(bufnr, old_end_row, tracker.status)
            return false
        end

        Renderer.clear_decoration_extmarks(
            bufnr,
            tracker.decoration_extmark_ids
        )
        Renderer.clear_status_namespace(bufnr, start_row, old_end_row)

        -- Clear diff highlights BEFORE set_lines. `line_hl_group` (DIFF_ADD/
        -- DIFF_DELETE) extmarks migrate to the edge of the replaced range when
        -- set_lines runs — to EOF when the block is the last thing in the
        -- buffer. A clear afterwards using the pre-edit range then misses the
        -- migrated marks, leaving an orphaned diff-bg highlight on a line
        -- outside the block. The re-render only runs for diffs on the failed
        -- transition, which is why this only bit failed edits.
        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            Renderer.NS_DIFF_HIGHLIGHTS,
            start_row,
            old_end_row + 1
        )

        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        -- Adjust _chunk_start_line for the line count change so that
        -- _reflow_chunks does not accidentally process tool call block
        -- lines after the block expands (e.g. diff data arriving late).
        local line_delta = new_end_row - old_end_row
        if line_delta ~= 0 and self._chunk_start_line then
            if self._chunk_start_line > old_end_row then
                self._chunk_start_line = self._chunk_start_line + line_delta
            elseif self._chunk_start_line > start_row then
                -- Chunk start was inside the old block range — push it
                -- past the new block so reflow never touches block lines.
                self._chunk_start_line = new_end_row + 1
            end
        end

        -- Same shift for the prose run anchor: prose is written after the
        -- most recent tool call, but updates can resize *older* blocks above
        -- it. The anchor must move with the lines it points to so the pin
        -- stays on the same content.
        if line_delta ~= 0 and self._prose_anchor_line then
            if self._prose_anchor_line > old_end_row then
                self._prose_anchor_line = self._prose_anchor_line + line_delta
            elseif self._prose_anchor_line >= start_row then
                -- Block ate the anchor line (shouldn't happen for prose
                -- written after this block, but bail out safely).
                self:_release_prose_pin()
            end
        end

        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                Renderer.apply_block_highlights(
                    bufnr,
                    start_row,
                    new_end_row,
                    tracker.kind,
                    highlight_ranges,
                    ansi_highlights,
                    tracker.search_matches,
                    tracker.search_ansi
                )
            end
        end)

        vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            start_row,
            0,
            {
                id = tracker.extmark_id,
                end_row = new_end_row,
                right_gravity = true,
                end_right_gravity = false,
            }
        )

        tracker.decoration_extmark_ids = Renderer.render_decorations(
            bufnr,
            start_row,
            new_end_row,
            self:_ordinal_sign(tracker)
        )

        -- Gated to final render — see the matching block in write_tool_call_block.
        if fold_anchor and is_final_status(tracker.status) then
            if fold_open then
                self:_open_fold(start_row + fold_anchor)
            else
                self:_close_fold(start_row + fold_anchor)
            end
        end
        if dim_range then
            local dim_id = Renderer.set_dim_range(
                bufnr,
                start_row + dim_range[1],
                start_row + dim_range[2]
            )
            table.insert(tracker.decoration_extmark_ids, dim_id)
        end

        Renderer.apply_status_footer(bufnr, new_end_row, tracker.status)

        materialize_injections(bufnr, start_row, new_end_row)
    end)
end

--- @private
--- @param err agentic.acp.ACPError
--- @return string[] lines
--- @return string|nil error_type
--- @return number|nil reset_epoch
function MessageWriter._format_error_lines(err)
    return format_error_lines(err)
end

--- @private
--- @param time_str string
--- @param tz string
--- @return number|nil epoch
function MessageWriter._parse_reset_time(time_str, tz)
    return parse_reset_time(time_str, tz)
end

return MessageWriter
