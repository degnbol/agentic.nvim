local configDefault = require("agentic.config_default")

-- A copy, so a merged user config leaves the defaults as they are.
--- @type agentic.UserConfig
local Config = vim.deepcopy(configDefault)

return Config
