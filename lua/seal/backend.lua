local M = {}

function M.name(config)
  if config.backend == "acp" then
    return config.acp.name or (config.acp.command and "ACP agent" or "Gemini")
  end
  return "Codex"
end

-- Both adapters expose Seal's thread/turn requests and review events. Protocol
-- framing and session translation stay outside the editor's queue and UI.
function M.new(config, callbacks)
  local adapter = require(config.backend == "acp" and "seal.acp" or "seal.client")
  return adapter.new(vim.tbl_extend("force", config, callbacks))
end

return M
