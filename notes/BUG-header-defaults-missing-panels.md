# Bug: panels missing from the `headers` defaults get a winbar

`Config.headers` (`config_default.lua`) sets `function() end` for `input`,
`files`, `agent`, `code`, `diagnostics` and `todos`. A function returning nil
means no header (`resolve_header_text` in `window_decoration.lua`), so with the
default `winbar = true` those panels get an empty winbar.

`agentic.ui.ChatWidget.PanelNames` also has `activity`, `info`, `subagent`
(transcripts) and `message` (subagent message inputs). These have no
`headers` entry. `resolve_header_text` reads a nil entry as "no customisation"
and renders the default parts, so these panels show a winbar while the others
do not.

`:h agentic-config-headers` names no panels, so neither the defaults nor the
doc says which behaviour is intended.

Reproduce: default config, open a subagent transcript, check its `winbar`
against the agent panel's.
