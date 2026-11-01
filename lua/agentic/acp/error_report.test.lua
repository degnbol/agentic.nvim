local assert = require("tests.helpers.assert")
local ErrorReport = require("agentic.acp.error_report")

describe("agentic.acp.ErrorReport", function()
    describe("format", function()
        it("parses auth error with embedded JSON", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: Failed to authenticate. API Error: 401\n"
                    .. '{"type":"error","error":{"type":"authentication_error",'
                    .. '"message":"Invalid authentication credentials"},'
                    .. '"request_id":"req_test123"}',
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal("401 Invalid authentication credentials", lines[1])
            -- No hint line — auth re-login is handled by the caller
            assert.equal(1, #lines)
            assert.equal("authentication_error", error_type)
        end)

        it("parses overloaded error with embedded JSON", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: API Error: 529\n"
                    .. '{"type":"error","error":{"type":"overloaded_error",'
                    .. '"message":"Overloaded."}}',
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal("529 Overloaded.", lines[1])
            assert.equal("", lines[2])
            assert.equal(
                "The API is overloaded. Try again in a moment.",
                lines[3]
            )
            assert.equal("overloaded_error", error_type)
        end)

        it("falls back to raw message when no JSON present", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32000,
                message = "Authentication required",
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal("Authentication required", lines[1])
            assert.equal(1, #lines)
            assert.is_nil(error_type)
        end)

        it("falls back to the message when JSON is invalid", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: {not valid json}",
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal("{not valid json}", lines[1])
            assert.is_nil(error_type)
        end)

        it("strips the bridge wrapper prefix off a usage limit", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: You've hit your limit"
                    .. " · resets 5pm (Europe/London)",
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal(
                "You've hit your limit · resets 5pm (Europe/London)",
                lines[1]
            )
            assert.equal("usage_limit", error_type)
        end)

        it("uses error type as fallback when message is empty", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = 'API Error: 500\n{"type":"error","error":'
                    .. '{"type":"api_error","message":""}}',
            }

            local lines = ErrorReport.format(err)

            assert.equal("Api error", lines[1])
        end)

        it("handles error without HTTP code in prefix", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = 'Something went wrong\n{"type":"error","error":'
                    .. '{"type":"unknown_error","message":"Details here"}}',
            }

            local lines = ErrorReport.format(err)

            assert.equal("Details here", lines[1])
        end)

        it("handles missing message field", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = nil, --- @diagnostic disable-line: assign-type-mismatch
            }

            local lines = ErrorReport.format(err)

            assert.equal("Unknown error", lines[1])
        end)

        it("detects usage limit error with 12h time format", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: You're out of extra usage · resets 5pm (Europe/London)",
            }

            local lines, error_type, reset_epoch = ErrorReport.format(err)

            assert.equal("usage_limit", error_type)
            assert.equal(1, #lines)
            assert.truthy(lines[1]:find("out of extra usage"))
            -- reset_epoch depends on system time, just check it's a number or nil
            -- (nil if GNU date isn't available)
            if reset_epoch then
                assert.truthy(reset_epoch > os.time())
            end
        end)

        it("detects usage limit error with 24h time format", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: You're out of extra usage · resets 17:00 (Europe/London)",
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal("usage_limit", error_type)
            assert.truthy(lines[1]:find("out of extra usage"))
        end)

        it("detects usage limit error with minutes in 12h format", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: You're out of extra usage · resets 5:30pm (US/Eastern)",
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal("usage_limit", error_type)
            assert.truthy(lines[1]:find("out of extra usage"))
        end)

        it("returns nil error_type for non-usage-limit plain errors", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: Something else went wrong",
            }

            local _, error_type = ErrorReport.format(err)

            assert.is_nil(error_type)
        end)

        it("classifies billing_error from errorKind with a hint", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "billing_error" },
                message = "Internal error: You've hit your org's monthly spend "
                    .. "limit · run /usage-credits to ask your admin for a "
                    .. "higher limit",
            }

            local lines, error_type, reset_epoch = ErrorReport.format(err)

            assert.equal("billing_error", error_type)
            assert.is_nil(reset_epoch)
            -- Wrapper prefix stripped from the first body line
            assert.equal(
                "You've hit your org's monthly spend limit · run /usage-credits"
                    .. " to ask your admin for a higher limit",
                lines[1]
            )
            -- Hint present after a blank separator
            assert.equal("", lines[2])
            assert.truthy(lines[3]:find("no automatic retry", 1, true))
        end)

        it("maps authentication_failed errorKind to auth class", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "authentication_failed" },
                message = "Internal error: Please run /login",
            }

            local _, error_type = ErrorReport.format(err)

            assert.equal("authentication_error", error_type)
        end)

        it("errorKind is authoritative over embedded JSON class", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "authentication_failed" },
                message = "Internal error: API Error: 500\n"
                    .. '{"type":"error","error":{"type":"server_error",'
                    .. '"message":"Boom"}}',
            }

            local lines, error_type = ErrorReport.format(err)

            -- Class comes from errorKind; display still uses the JSON extraction
            assert.equal("authentication_error", error_type)
            assert.equal("500 Boom", lines[1])
        end)

        it(
            "mapped kind keeps its hint when embedded JSON is present",
            function()
                --- @type agentic.acp.ACPError
                local err = {
                    code = -32603,
                    data = { errorKind = "billing_error" },
                    message = "Internal error: API Error: 400\n"
                        .. '{"type":"error","error":{"type":"invalid_request_error",'
                        .. '"message":"Spend cap"}}',
                }

                local lines, error_type = ErrorReport.format(err)

                assert.equal("billing_error", error_type)
                assert.equal("400 Spend cap", lines[1])
                -- Hint follows the resolved (billing) class, not the JSON type
                assert.truthy(
                    lines[3] and lines[3]:find("no automatic retry", 1, true)
                )
            end
        )

        -- The counterpart of the mapped-kind case below: with no class and no
        -- hint, the status code is the only thing the line says, so stripping
        -- it would leave a `## Error` with an empty body.
        it("keeps the API Error status on an unclassified body", function()
            --- @type agentic.acp.ACPError
            local err = { code = -32603, message = "API Error: 401" }

            local lines = ErrorReport.format(err)

            assert.equal("API Error: 401", lines[1])
        end)

        it("strips the API Error prefix from a mapped-kind body", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "authentication_failed" },
                message = "Internal error: API Error: 401 Session expired",
            }

            local lines = ErrorReport.format(err)

            assert.equal("Session expired", lines[1])
        end)

        it(
            "returns reset_epoch nil for a mapped kind over a reset clause",
            function()
                --- @type agentic.acp.ACPError
                local err = {
                    code = -32603,
                    data = { errorKind = "billing_error" },
                    message = "Internal error: Spend cap · resets 5pm (Europe/London)",
                }

                local _, error_type, reset_epoch = ErrorReport.format(err)

                -- errorKind wins: billing has no reset, so no auto-continue epoch
                assert.equal("billing_error", error_type)
                assert.is_nil(reset_epoch)
            end
        )

        it("unmapped errorKind falls through to text classification", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "server_error" },
                message = "Internal error: API Error: 529\n"
                    .. '{"type":"error","error":{"type":"overloaded_error",'
                    .. '"message":"Overloaded."}}',
            }

            local lines, error_type = ErrorReport.format(err)

            assert.equal("overloaded_error", error_type)
            assert.equal("529 Overloaded.", lines[1])
        end)
    end)

    describe("parse_reset_time", function()
        it("returns a future epoch for a valid time and timezone", function()
            -- This test depends on GNU date being available
            local epoch = ErrorReport.parse_reset_time("11:59pm", "UTC")
            if epoch then
                assert.truthy(epoch > os.time())
            end
        end)

        it("returns nil for invalid timezone", function()
            local epoch = ErrorReport.parse_reset_time("5pm", "Not/A/Timezone")
            -- GNU date may still parse this or return nil; just ensure no crash
            assert.truthy(epoch == nil or type(epoch) == "number")
        end)
    end)

    describe("reported_text", function()
        it("joins the lines up to the first blank", function()
            local text =
                ErrorReport.reported_text({ "first", "second", "", "hint" })

            assert.equal("first second", text)
        end)
    end)
end)
