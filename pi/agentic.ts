// pi extension loaded by agentic.nvim (`pi --extension`): every tool call
// goes to the client for a permission decision before it runs. The client
// reads the select's title (prefix + JSON of the call) and answers with one
// of the option ids.
//
// A patched pi-claude-bridge emits Claude Code's auto mode verdict for each
// tool call on `claude-bridge:safeguard` before pi's `tool_call`. The title
// JSON carries it as `safeguard`.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const TITLE_PREFIX = "agentic-permission:";
const OPTION_IDS = ["allow_once", "allow_always", "reject_once", "reject_always"];

type Safeguard = { outcome: string; citedRule?: string };

export default function (pi: ExtensionAPI) {
  const safeguards = new Map<string, Safeguard>();

  pi.events.on("claude-bridge:safeguard", (data) => {
    const { toolCallId, outcome, citedRule } = data as Safeguard & { toolCallId: string };
    safeguards.set(toolCallId, { outcome, citedRule });
  });
  pi.on("turn_end", () => safeguards.clear());

  pi.on("tool_call", async (event, ctx) => {
    const safeguard = safeguards.get(event.toolCallId);
    safeguards.delete(event.toolCallId);
    const title =
      TITLE_PREFIX +
      JSON.stringify({ toolCallId: event.toolCallId, toolName: event.toolName, input: event.input, safeguard });
    const choice = await ctx.ui.select(title, OPTION_IDS, {
      signal: ctx.signal,
      blockedKind: "permission",
    });
    if (choice !== "allow_once" && choice !== "allow_always") {
      return { block: true, reason: "Rejected in agentic.nvim" };
    }
  });
}
