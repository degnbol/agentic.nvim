--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Recovery = require("agentic.session_recovery")

describe("agentic.session_recovery", function()
    describe("auto-continue after a usage limit", function()
        --- @type TestSpy
        local submit_spy

        --- @param drained boolean Whether queued regions supplied the continuation
        --- @return agentic.SessionManager
        local function session_with(drained)
            submit_spy = spy.new(function() end)
            return {
                session_id = "s1",
                _destroyed = false,
                _retry_attempt = 1,
                _usage_reset_epoch = os.time() + 600,
                _handle_input_submit = submit_spy,
                _drain_queue = function()
                    return drained
                end,
            } --[[@as agentic.SessionManager]]
        end

        it("sends 'continue' when nothing was queued", function()
            local session = session_with(false)

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(1)
            assert.equal("continue", submit_spy.calls[1][2])
        end)

        -- The queued regions ARE the continuation; an extra "continue" would
        -- fire a second concurrent turn.
        it("sends no 'continue' when queued regions drained", function()
            local session = session_with(true)

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(0)
        end)

        -- The gate must open first, or it would defer both branches above and
        -- the pause would never end.
        it("releases the usage gate before dispatching", function()
            local session = session_with(false)
            local epoch_at_submit
            session._handle_input_submit = spy.new(function(sm)
                epoch_at_submit = sm._usage_reset_epoch
            end)

            Recovery._fire_auto_continue(session)

            assert.is_nil(epoch_at_submit)
            assert.is_nil(session._usage_reset_epoch)
        end)

        -- cancel_retry_timer(sm, false) spares the attempt counter. Resetting
        -- it would stop offer_auto_continue's MAX_RETRIES check from ever
        -- tripping, retrying every 130s indefinitely.
        it("keeps the attempt counter so a repeat limit backs off", function()
            local session = session_with(false)

            Recovery._fire_auto_continue(session)

            assert.equal(1, session._retry_attempt)
        end)

        it("sends nothing for a destroyed session", function()
            local session = session_with(false)
            session._destroyed = true

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(0)
        end)

        -- respawn_after_usage_limit clears session_id and repopulates it from
        -- an async new_session, so this window is reachable. An unprompted turn
        -- must not land on a half-respawned provider.
        it("sends nothing without a session", function()
            local session = session_with(false)
            session.session_id = nil

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(0)
        end)
    end)
end)
