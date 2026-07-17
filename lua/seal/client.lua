local Client = {}
Client.__index = Client

local function bridge_path()
  local paths = vim.api.nvim_get_runtime_file("bin/seal-bridge", false)
  return paths[1]
end

local function default_transport(opts, on_line, on_exit)
  local script = opts.bridge or bridge_path()
  if not script then
    return nil, "Seal bridge is not built; run `go build -o bin/seal-bridge ./cmd/seal-bridge`"
  end

  local partial = ""
  local stopping = false
  local job

  local function consume(data)
    if not data or #data == 0 then
      return
    end

    local lines = vim.deepcopy(data)
    lines[1] = partial .. (lines[1] or "")
    partial = table.remove(lines) or ""
    for _, line in ipairs(lines) do
      if line ~= "" then
        on_line(line)
      end
    end
  end

  job = vim.fn.jobstart({ script, "--codex", opts.codex_command }, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      consume(data)
    end,
    on_stderr = function(_, data)
      if opts.on_log and data then
        for _, line in ipairs(data) do
          if line ~= "" then
            opts.on_log(line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if partial ~= "" then
        on_line(partial)
        partial = ""
      end
      on_exit(code, stopping)
    end,
  })

  if job <= 0 then
    return nil, "could not start the Seal bridge"
  end

  return {
    send = function(_, line)
      return vim.fn.chansend(job, line .. "\n") > 0
    end,
    stop = function()
      stopping = true
      if job and job > 0 then
        pcall(vim.fn.jobstop, job)
      end
    end,
  }
end

function Client.new(opts)
  opts = opts or {}
  return setmetatable({
    opts = {
      bridge = opts.bridge,
      codex_command = opts.codex_command or "codex",
      on_notification = opts.on_notification,
      on_server_request = opts.on_server_request,
      on_error = opts.on_error,
      on_exit = opts.on_exit,
      on_log = opts.on_log,
    },
    transport_factory = opts.transport_factory or default_transport,
    transport = nil,
    ready = false,
    starting = false,
    stopping = false,
    remote_url = nil,
    next_id = 1,
    pending = {},
    waiters = {},
  }, Client)
end

function Client:_error(message)
  if self.opts.on_error then
    self.opts.on_error(message)
  end
end

function Client:_send(message)
  if not self.transport then
    return false
  end
  return self.transport:send(vim.json.encode(message))
end

function Client:_request(method, params, callback)
  local id = self.next_id
  self.next_id = id + 1
  self.pending[tostring(id)] = callback or function() end
  if not self:_send({ id = id, method = method, params = params or {} }) then
    self.pending[tostring(id)] = nil
    if callback then
      callback(nil, { message = "Codex app-server is not connected" })
    end
  end
  return id
end

function Client:_finish_start(error_message)
  self.starting = false
  self.ready = error_message == nil
  local waiters = self.waiters
  self.waiters = {}
  for _, callback in ipairs(waiters) do
    callback(self.ready, error_message)
  end
end

function Client:_handle(message)
  if type(message) == "string" then
    local ok, decoded = pcall(vim.json.decode, message)
    if not ok then
      self:_error("invalid app-server message: " .. tostring(decoded))
      return
    end
    message = decoded
  end

  if type(message) ~= "table" then
    return
  end

  if message.seal then
    if message.seal.event == "ready" then
      self.remote_url = message.seal.url
      self:_request("initialize", {
        clientInfo = { name = "seal", title = "Seal", version = "0.1.0" },
        capabilities = { experimentalApi = true },
      }, function(_, err)
        if err then
          if self.transport then
            self.transport:stop()
            self.transport = nil
          end
          self:_finish_start(err.message or "Codex initialization failed")
          return
        end
        self:_send({ method = "initialized" })
        self:_finish_start()
      end)
    elseif message.seal.event == "error" then
      self:_error(message.seal.message or "Seal bridge failed")
    end
    return
  end

  if message.id ~= nil and message.method == nil then
    local callback = self.pending[tostring(message.id)]
    if callback then
      self.pending[tostring(message.id)] = nil
      callback(message.result, message.error)
    end
    return
  end

  if message.id ~= nil and message.method ~= nil then
    if self.opts.on_server_request then
      self.opts.on_server_request(message)
    end
    return
  end

  if message.method and self.opts.on_notification then
    self.opts.on_notification(message.method, message.params or {})
  end
end

function Client:start(callback)
  callback = callback or function() end
  if self.ready then
    callback(true)
    return
  end

  table.insert(self.waiters, callback)
  if self.starting then
    return
  end

  self.starting = true
  self.stopping = false
  local transport, err = self.transport_factory(self.opts, function(line)
    vim.schedule(function()
      self:_handle(line)
    end)
  end, function(code, expected)
    vim.schedule(function()
      self.transport = nil
      self.ready = false
      self.starting = false
      self.remote_url = nil
      local pending = self.pending
      self.pending = {}
      for _, pending_callback in pairs(pending) do
        pending_callback(nil, { message = "Codex app-server exited" })
      end
      if #self.waiters > 0 then
        self:_finish_start("Codex app-server exited")
      end
      if self.opts.on_exit then
        self.opts.on_exit(code, expected)
      end
    end)
  end)

  if not transport then
    self:_finish_start(err)
    self:_error(err)
    return
  end
  self.transport = transport
end

function Client:request(method, params, callback)
  if not self.ready then
    callback(nil, { message = "Codex app-server is not ready" })
    return nil
  end
  return self:_request(method, params, callback)
end

function Client:respond(id, result)
  return self:_send({ id = id, result = result or {} })
end

function Client:respond_error(id, code, message)
  return self:_send({ id = id, error = { code = code, message = message } })
end

function Client:url()
  return self.remote_url
end

function Client:stop()
  self.stopping = true
  self.ready = false
  self.starting = false
  if self.transport then
    self.transport:stop()
    self.transport = nil
  end
end

-- Test seam for protocol messages that do not need a process.
function Client:_feed(message)
  self:_handle(message)
end

return Client
