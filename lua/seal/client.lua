-- Codex app-server uses Seal's bridge readiness message before initialization.
-- The shared RPC client owns framing, request deadlines, and process lifetime.
local Rpc = require("seal.rpc")
local Client = {}

local function bridge_transport(opts, on_line, on_exit)
  local script = opts.bridge or vim.api.nvim_get_runtime_file("bin/seal-bridge", false)[1]
  if not script then
    return nil, "Seal bridge is not built; run `go build -o bin/seal-bridge ./cmd/seal-bridge`"
  end
  opts.command = { script, "--codex", opts.codex_command }
  return Rpc.stdio_transport(opts, on_line, on_exit)
end

local function bridge_control(self, message, generation, transport)
  if message.seal then
    if message.seal.event == "ready" then
      self.remote_url = message.seal.url
      self:_request("initialize", {
        clientInfo = { name = "seal", title = "Seal", version = "0.1.0" },
        capabilities = { experimentalApi = true },
      }, function(_, err)
        if self.transport_generation ~= generation or self.transport ~= transport then
          return
        end
        if err then
          self:_abort_transport(
            generation,
            transport,
            err.message or "Codex initialization failed",
            true
          )
          return
        end
        local sent, send_error = self:_send({ method = "initialized" }, generation, transport)
        if not sent then
          self:_abort_transport(generation, transport, send_error, true)
          return
        end
        self:_finish_start()
      end, generation, transport)
    elseif message.seal.event == "error" then
      self:_error(message.seal.message or "Seal bridge failed")
    end
    return true
  end
end

function Client.new(opts)
  opts = vim.tbl_extend("force", {
    name = "Codex app-server",
    codex_command = "codex",
    transport_factory = bridge_transport,
    on_control = bridge_control,
  }, opts or {})
  return Rpc.new(opts)
end

return Client
