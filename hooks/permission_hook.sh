#!/usr/bin/env sh
# claude-agent-acp PreToolUse hook for agentic.nvim.
#
# Runs the plugin's deterministic permission ladder inside the live nvim,
# ahead of auto-mode's SDK classifier, and maps the verdict onto a PreToolUse
# permissionDecision (allow / deny / undecided). See permission_hook.lua and
# notes/PLAN-auto-mode-integration.md.
#
# Self-scoping: only fires inside an nvim that exported AGENTIC_SOCK. A plain
# `claude` CLI run in the same cwd never gets the var, so this no-ops for it.
#
# Fail-open by design: any missing socket, RPC error, or empty verdict emits no
# output, so the call falls through to the classifier — never a spurious allow.

[ -z "$AGENTIC_SOCK" ] && exit 0

# base64 sidesteps all shell/vimscript quoting of the JSON payload; it is
# single-quote-safe, so it drops straight into the --remote-expr string.
payload=$(base64 | tr -d '\n')

expr="luaeval('require(\"agentic.permission_hook\").evaluate(_A)', '${payload}')"
verdict=$(nvim --server "$AGENTIC_SOCK" --remote-expr "$expr" 2>/dev/null) || exit 0

case "$verdict" in
    allow)
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"agentic.nvim permission ladder"}}\n'
        ;;
    deny)
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"agentic.nvim permission ladder"}}\n'
        ;;
    *)
        : # undecided -> no output, classifier decides
        ;;
esac

exit 0
