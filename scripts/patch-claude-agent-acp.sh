#!/usr/bin/env bash
# Patch claude-agent-acp so subagent (Task) prose reaches the subagents window.
#
# The bridge filters a subagent assistant message's text/thinking blocks before
# emitting session/update notifications, so the subagents window only ever shows
# tool calls (dist/acp-agent.js, the `message.type === "assistant"` branch). The
# ACP client already routes parentToolUseId-tagged prose to the subagents buffer;
# forwarding it is a one-line change to the compiled bridge.
#
# Idempotent and re-runnable after every claude-agent-acp upgrade. If the target
# code moved (upstream refactor), it fails loudly rather than silently no-op'ing.
set -euo pipefail

MARKER='agentic.nvim: forward subagent prose'
OLD='content = message.message.content.filter((item) => item.type !== "text" && item.type !== "thinking");'
NEW="content = message.message.content; /* $MARKER */"

resolve_symlink() {
    # Portable `readlink -f` (BSD readlink lacks -f): walk the symlink chain.
    local path="$1" target
    while [ -L "$path" ]; do
        target="$(readlink "$path")"
        case "$target" in
        /*) path="$target" ;;
        *) path="$(dirname "$path")/$target" ;;
        esac
    done
    printf '%s' "$path"
}

bin="$(command -v claude-agent-acp || true)"
[ -n "$bin" ] || {
    echo "error: claude-agent-acp not found on PATH" >&2
    exit 1
}

target="$(dirname "$(resolve_symlink "$bin")")/acp-agent.js"
[ -f "$target" ] || {
    echo "error: $target not found (unexpected install layout)" >&2
    exit 1
}

if grep -qF "$MARKER" "$target"; then
    echo "already patched: $target"
    exit 0
fi

if ! grep -qF "$OLD" "$target"; then
    echo "error: target code not found in $target" >&2
    echo "claude-agent-acp likely changed; check for an updated patch." >&2
    exit 1
fi

OLD="$OLD" NEW="$NEW" perl -i -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$target"

grep -qF "$MARKER" "$target" || {
    echo "error: patch verification failed for $target" >&2
    exit 1
}
echo "patched: $target"
