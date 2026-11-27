// pi extension loaded by agentic.nvim (`pi --extension`): every tool call
// goes to the client for a permission decision before it runs. The client
// reads the select's title (prefix + JSON of the call) and answers with one
// of the option ids.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const TITLE_PREFIX = "agentic-permission:";
const OPTION_IDS = ["allow_once", "allow_always", "reject_once", "reject_always"];

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    const title =
      TITLE_PREFIX +
      JSON.stringify({ toolCallId: event.toolCallId, toolName: event.toolName, input: event.input });
    const choice = await ctx.ui.select(title, OPTION_IDS, {
      signal: ctx.signal,
      blockedKind: "permission",
    });
    if (choice !== "allow_once" && choice !== "allow_always") {
      return { block: true, reason: "Rejected in agentic.nvim" };
    }
  });
}
