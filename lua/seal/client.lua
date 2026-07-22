local Client = {}
Client.__index = Client

local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function valid_utf8(value)
  local index = 1
  while index <= #value do
    local first = value:byte(index)
    if first < 0x80 then
      index = index + 1
    else
      local second = value:byte(index + 1)
      local third = value:byte(index + 2)
      local fourth = value:byte(index + 3)
      local continuation2 = second and second >= 0x80 and second <= 0xBF
      local continuation3 = third and third >= 0x80 and third <= 0xBF
      local continuation4 = fourth and fourth >= 0x80 and fourth <= 0xBF
      if first >= 0xC2 and first <= 0xDF and continuation2 then
        index = index + 2
      elseif first == 0xE0 and second and second >= 0xA0 and second <= 0xBF and continuation3 then
        index = index + 3
      elseif first >= 0xE1 and first <= 0xEC and continuation2 and continuation3 then
        index = index + 3
      elseif first == 0xED and second and second >= 0x80 and second <= 0x9F and continuation3 then
        index = index + 3
      elseif first >= 0xEE and first <= 0xEF and continuation2 and continuation3 then
        index = index + 3
      elseif first == 0xF0 and second and second >= 0x90 and second <= 0xBF
        and continuation3 and continuation4
      then
        index = index + 4
      elseif first >= 0xF1 and first <= 0xF3 and continuation2 and continuation3 and continuation4 then
        index = index + 4
      elseif first == 0xF4 and second and second >= 0x80 and second <= 0x8F
        and continuation3 and continuation4
      then
        index = index + 4
      else
        return false
      end
    end
  end
  return true
end

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
      startup_timeout_ms = opts.startup_timeout_ms or 10000,
      request_timeout_ms = opts.request_timeout_ms or 30000,
    },
    transport_factory = opts.transport_factory or default_transport,
    transport = nil,
    ready = false,
    starting = false,
    remote_url = nil,
    next_id = 1,
    pending = {},
    waiters = {},
    transport_generation = 0,
    startup_timer = nil,
  }, Client)
end

function Client:_error(message)
  if self.opts.on_error then
    self.opts.on_error(message)
  end
end

function Client:_send(message, generation, transport)
  transport = transport or self.transport
  generation = generation or self.transport_generation
  if not transport
    or self.transport ~= transport
    or self.transport_generation ~= generation
  then
    return false, "Codex app-server is not connected"
  end
  local encoded_ok, encoded = pcall(vim.json.encode, message)
  if not encoded_ok then
    return false, "could not encode app-server message: " .. tostring(encoded)
  end
  if not valid_utf8(encoded) then
    return false, "app-server messages must contain valid UTF-8"
  end
  if not transport:send(encoded) then
    return false, "could not send the app-server message"
  end
  return true
end

function Client:_request(method, params, callback, generation, transport)
  generation = generation or self.transport_generation
  transport = transport or self.transport
  local id = self.next_id
  self.next_id = id + 1
  local key = tostring(id)
  local pending = {
    callback = callback or function() end,
    generation = generation,
    transport = transport,
    method = method,
  }
  self.pending[key] = pending
  local sent, send_error = self:_send(
    { id = id, method = method, params = params or {} },
    generation,
    transport
  )
  if not sent then
    self.pending[key] = nil
    pending.callback(nil, { message = send_error })
    return id
  end
  local timeout = math.max(1, tonumber(self.opts.request_timeout_ms) or 30000)
  pending.timer = vim.defer_fn(function()
    if self.pending[key] ~= pending then
      return
    end
    local message = string.format(
      "Codex app-server request timed out after %d ms: %s",
      timeout,
      pending.method
    )
    -- A mutating request can still complete after its local timer fires. The
    -- client cannot safely correlate that late result after reporting failure,
    -- so retire the whole transport generation before another request starts.
    if not self:_abort_transport(pending.generation, pending.transport, message, true) then
      self.pending[key] = nil
      pending.callback(nil, { message = message })
    end
  end, timeout)
  return id
end

function Client:_fail_pending(message)
  local pending = self.pending
  self.pending = {}
  for _, request in pairs(pending) do
    stop_timer(request.timer)
    request.callback(nil, { message = message })
  end
end

function Client:_finish_start(error_message)
  stop_timer(self.startup_timer)
  self.startup_timer = nil
  self.starting = false
  self.ready = error_message == nil
  local waiters = self.waiters
  self.waiters = {}
  for _, callback in ipairs(waiters) do
    callback(self.ready, error_message)
  end
end

function Client:_abort_transport(generation, transport, message, expected)
  if self.transport_generation ~= generation or self.transport ~= transport then
    return false
  end
  self.transport_generation = self.transport_generation + 1
  self.transport = nil
  self.ready = false
  self.remote_url = nil
  local had_waiters = self.starting or #self.waiters > 0
  self.starting = false
  stop_timer(self.startup_timer)
  self.startup_timer = nil
  self:_fail_pending(message)
  if had_waiters then
    self:_finish_start(message)
  end
  transport:stop()
  if self.opts.on_exit then
    self.opts.on_exit(expected and 0 or -1, expected == true)
  end
  return true
end

function Client:_handle(message, generation, transport)
  generation = generation or self.transport_generation
  transport = transport or self.transport
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
    return
  end

  if message.id ~= nil and message.method == nil then
    local pending = self.pending[tostring(message.id)]
    if pending then
      self.pending[tostring(message.id)] = nil
      stop_timer(pending.timer)
      pending.callback(message.result, message.error)
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
  self.transport_generation = self.transport_generation + 1
  local generation = self.transport_generation
  local transport, err
  transport, err = self.transport_factory(self.opts, function(line)
    vim.schedule(function()
      if self.transport_generation == generation and self.transport == transport then
        self:_handle(line, generation, transport)
      end
    end)
  end, function(code, expected)
    vim.schedule(function()
      if self.transport_generation ~= generation or self.transport ~= transport then
        return
      end
      self.transport_generation = self.transport_generation + 1
      self.transport = nil
      self.ready = false
      self.starting = false
      self.remote_url = nil
      self:_fail_pending("Codex app-server exited")
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
  if self.starting then
    local timeout = math.max(1, tonumber(self.opts.startup_timeout_ms) or 10000)
    self.startup_timer = vim.defer_fn(function()
      if self.transport_generation ~= generation
        or self.transport ~= transport
        or not self.starting
      then
        return
      end
      local message = string.format("Codex app-server startup timed out after %d ms", timeout)
      if self:_abort_transport(generation, transport, message, true) then
        self:_error(message)
      end
    end, timeout)
  end
end

function Client:request(method, params, callback)
  callback = callback or function() end
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
  local generation = self.transport_generation
  local transport = self.transport
  if transport then
    self:_abort_transport(generation, transport, "Codex app-server stopped", true)
    return
  end
  self.ready = false
  self.starting = false
  self.remote_url = nil
  stop_timer(self.startup_timer)
  self.startup_timer = nil
  self:_fail_pending("Codex app-server stopped")
end

-- Test seam for protocol messages that do not need a process.
function Client:_feed(message)
  self:_handle(message, self.transport_generation, self.transport)
end

return Client
