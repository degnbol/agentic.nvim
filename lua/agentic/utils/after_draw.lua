--- Run callbacks after a window's next draw. A `vim.schedule` from the code
--- that opens a window runs before the window's first draw.
--- @class agentic.utils.AfterDraw
local AfterDraw = {}

local NS = vim.api.nvim_create_namespace("agentic_after_draw")

--- Callbacks per window, waiting for a redraw that draws the window.
--- @type table<integer, fun()[]>
local pending = {}

--- Pending windows the current redraw has drawn so far.
--- @type table<integer, true>
local drawn = {}

local registered = false

local function register()
    vim.api.nvim_set_decoration_provider(NS, {
        on_start = function()
            drawn = {}
            return next(pending) ~= nil
        end,
        on_win = function(_, winid)
            if pending[winid] then
                drawn[winid] = true
            end
            return false
        end,
        on_end = function()
            for winid, fns in pairs(pending) do
                if drawn[winid] then
                    pending[winid] = nil
                    -- One schedule each, so an error in one leaves the
                    -- others to run.
                    for _, fn in ipairs(fns) do
                        vim.schedule(function()
                            if vim.api.nvim_win_is_valid(winid) then
                                fn()
                            end
                        end)
                    end
                elseif not vim.api.nvim_win_is_valid(winid) then
                    pending[winid] = nil
                end
            end
        end,
    })
    registered = true
end

--- Call `fn` once, scheduled after the end of the first redraw that draws
--- `winid`. Not called when the window closes before then.
--- @param winid integer
--- @param fn fun()
function AfterDraw.once(winid, fn)
    if not registered then
        register()
    end
    pending[winid] = pending[winid] or {}
    table.insert(pending[winid], fn)
end

return AfterDraw
