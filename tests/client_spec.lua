local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local Client = require("seal.client")

local function format(value)
  return vim.inspect(value)
end

local function fail(message)
  error(message, 2)
end

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail((message and (message .. "\n") or "") .. "expected: " .. format(expected) .. "\nactual:   " .. format(actual))
  end
end

local function assert_true(value, message)
  if not value then
    fail(message or ("expected truthy value, got " .. format(value)))
  end
end

local function wait_until(predicate, message)
  if not vim.wait(1000, predicate, 1) then
    fail(message or "timed out waiting for scheduled callback")
  end
end

local function new_fake_transport(options)
  options = options or {}
  local fake = {
    factory_calls = 0,
    sent = {},
    stop_calls = 0,
    send_ok = true,
    runs = {},
  }

  function fake.factory(_, on_line, on_exit)
    fake.factory_calls = fake.factory_calls + 1
    local run = { on_line = on_line, on_exit = on_exit }
    table.insert(fake.runs, run)
    fake.on_line = on_line
    fake.on_exit = on_exit
    run.transport = {
      send = function(_, line)
        table.insert(fake.sent, vim.json.decode(line))
        return fake.send_ok
      end,
      stop = function()
        fake.stop_calls = fake.stop_calls + 1
        if options.exit_on_stop then
          on_exit(0, true)
        end
      end,
    }
    fake.transport = run.transport
    return run.transport
  end

  function fake:emit(message)
    assert_true(self.on_line, "transport has not started")
    self.on_line(type(message) == "string" and message or vim.json.encode(message))
  end

  function fake:exit(code, expected)
    assert_true(self.on_exit, "transport has not started")
    self.on_exit(code, expected or false)
  end

  return fake
end

local function start_ready(client, fake)
  local completed
  client:start(function(ok, err)
    completed = { ok = ok, err = err }
  end)

  fake:emit({ seal = { event = "ready", url = "ws://127.0.0.1:4500" } })
  wait_until(function()
    return #fake.sent == 1
  end, "initialize request was not sent")

  local initialize = fake.sent[1]
  assert_equal("initialize", initialize.method)
  fake:emit({ id = initialize.id, result = {} })
  wait_until(function()
    return completed ~= nil
  end, "start callback was not called")
  assert_equal({ ok = true }, completed)
  return initialize
end

local tests = {}

local function test(name, body)
  table.insert(tests, { name = name, body = body })
end

test("waits for bridge readiness and initialization before becoming ready", function()
  local fake = new_fake_transport()
  local client = Client.new({ transport_factory = fake.factory })
  local callbacks = {}

  client:start(function(ok, err)
    table.insert(callbacks, { ok = ok, err = err, sent_count = #fake.sent })
  end)
  client:start(function(ok, err)
    table.insert(callbacks, { ok = ok, err = err, sent_count = #fake.sent })
  end)

  assert_equal(1, fake.factory_calls, "concurrent starts should share one transport")
  assert_equal(0, #fake.sent, "initialize must wait for the bridge ready event")
  assert_equal(0, #callbacks)
  assert_equal(false, client.ready)

  fake:emit({ seal = { event = "ready", url = "ws://127.0.0.1:4510" } })
  wait_until(function()
    return #fake.sent == 1
  end)

  local initialize = fake.sent[1]
  assert_equal("initialize", initialize.method)
  assert_equal("seal", initialize.params.clientInfo.name)
  assert_equal(true, initialize.params.capabilities.experimentalApi)
  assert_equal("ws://127.0.0.1:4510", client:url())
  assert_equal(0, #callbacks, "start must wait for the initialize response")
  assert_equal(false, client.ready)

  fake:emit({ id = initialize.id, result = { userAgent = "test" } })
  wait_until(function()
    return #callbacks == 2
  end)

  assert_equal({ id = nil, method = "initialized", params = nil }, {
    id = fake.sent[2].id,
    method = fake.sent[2].method,
    params = fake.sent[2].params,
  })
  assert_equal({
    { ok = true, sent_count = 2 },
    { ok = true, sent_count = 2 },
  }, callbacks, "initialized must be sent before start callbacks run")
  assert_equal(true, client.ready)
end)

test("correlates out-of-order responses with their requests", function()
  local fake = new_fake_transport()
  local client = Client.new({ transport_factory = fake.factory })
  start_ready(client, fake)

  local results = {}
  local first_id = client:request("thread/start", { cwd = "/repo" }, function(result, err)
    table.insert(results, { request = "first", result = result, err = err })
  end)
  local second_id = client:request("turn/start", { prompt = "hello" }, function(result, err)
    table.insert(results, { request = "second", result = result, err = err })
  end)

  assert_true(first_id ~= second_id)
  assert_equal({ id = first_id, method = "thread/start", params = { cwd = "/repo" } }, fake.sent[3])
  assert_equal({ id = second_id, method = "turn/start", params = { prompt = "hello" } }, fake.sent[4])

  fake:emit({ id = second_id, error = { code = -32000, message = "rejected" } })
  fake:emit({ id = first_id, result = { thread = { id = "thread-1" } } })
  wait_until(function()
    return #results == 2
  end)

  assert_equal({
    { request = "second", err = { code = -32000, message = "rejected" } },
    { request = "first", result = { thread = { id = "thread-1" } } },
  }, results)

  fake:emit({ id = 999, result = { ignored = true } })
  vim.wait(10)
  assert_equal(2, #results, "unknown response IDs should be ignored")
end)

test("delivers notifications with default parameters", function()
  local notifications = {}
  local fake = new_fake_transport()
  local client = Client.new({
    transport_factory = fake.factory,
    on_notification = function(method, params)
      table.insert(notifications, { method = method, params = params })
    end,
  })
  start_ready(client, fake)

  fake:emit({ method = "turn/started", params = { turn = { id = "turn-1" } } })
  fake:emit({ method = "thread/compacted" })
  wait_until(function()
    return #notifications == 2
  end)

  assert_equal({
    { method = "turn/started", params = { turn = { id = "turn-1" } } },
    { method = "thread/compacted", params = {} },
  }, notifications)
end)

test("delivers server requests and sends success or error responses", function()
  local requests = {}
  local fake = new_fake_transport()
  local client
  client = Client.new({
    transport_factory = fake.factory,
    on_server_request = function(request)
      table.insert(requests, request)
      if request.method == "item/tool/call" then
        client:respond(request.id, { approved = true })
      else
        client:respond_error(request.id, -32601, "unsupported")
      end
    end,
  })
  start_ready(client, fake)

  fake:emit({ id = 41, method = "item/tool/call", params = { command = "rg seal" } })
  fake:emit({ id = 42, method = "unknown/request" })
  wait_until(function()
    return #requests == 2 and #fake.sent == 4
  end)

  assert_equal({ id = 41, method = "item/tool/call", params = { command = "rg seal" } }, requests[1])
  assert_equal({ id = 42, method = "unknown/request" }, requests[2])
  assert_equal({ id = 41, result = { approved = true } }, fake.sent[3])
  assert_equal({ id = 42, error = { code = -32601, message = "unsupported" } }, fake.sent[4])
end)

test("reports bridge protocol errors", function()
  local errors = {}
  local fake = new_fake_transport()
  local client = Client.new({
    transport_factory = fake.factory,
    on_error = function(message)
      table.insert(errors, message)
    end,
  })

  client:start()
  fake:emit({ seal = { event = "error", message = "could not bind websocket" } })
  wait_until(function()
    return #errors == 1
  end)
  assert_equal({ "could not bind websocket" }, errors)
  assert_equal(false, client.ready)
end)

test("fails startup when the bridge transport cannot be created", function()
  local errors = {}
  local started
  local client = Client.new({
    transport_factory = function()
      return nil, "bridge executable is missing"
    end,
    on_error = function(message)
      table.insert(errors, message)
    end,
  })

  client:start(function(ok, err)
    started = { ok = ok, err = err }
  end)

  assert_equal({ ok = false, err = "bridge executable is missing" }, started)
  assert_equal({ "bridge executable is missing" }, errors)
  assert_equal(false, client.ready)
  assert_equal(false, client.starting)
end)

test("fails startup when the bridge exits before initialization", function()
  local fake = new_fake_transport()
  local exited
  local started
  local client = Client.new({
    transport_factory = fake.factory,
    on_exit = function(code, expected)
      exited = { code = code, expected = expected }
    end,
  })

  client:start(function(ok, err)
    started = { ok = ok, err = err }
  end)
  fake:exit(17, false)
  wait_until(function()
    return started ~= nil and exited ~= nil
  end)

  assert_equal({ ok = false, err = "Codex app-server exited" }, started)
  assert_equal({ code = 17, expected = false }, exited)
  assert_equal(false, client.ready)
  assert_equal(nil, client:url())
end)

test("fails pending requests and resets state when the bridge exits", function()
  local fake = new_fake_transport()
  local exited
  local pending
  local client = Client.new({
    transport_factory = fake.factory,
    on_exit = function(code, expected)
      exited = { code = code, expected = expected }
    end,
  })
  start_ready(client, fake)

  client:request("thread/resume", { threadId = "thread-1" }, function(result, err)
    pending = { result = result, err = err }
  end)
  fake:exit(9, false)
  wait_until(function()
    return pending ~= nil and exited ~= nil
  end)

  assert_equal({ err = { message = "Codex app-server exited" } }, pending)
  assert_equal({ code = 9, expected = false }, exited)
  assert_equal(false, client.ready)
  assert_equal(nil, client:url())

  local not_ready
  local id = client:request("thread/start", {}, function(_, err)
    not_ready = err
  end)
  assert_equal(nil, id)
  assert_equal({ message = "Codex app-server is not ready" }, not_ready)
end)

test("stops the transport and rejects subsequent requests", function()
  local fake = new_fake_transport({ exit_on_stop = true })
  local exited
  local client = Client.new({
    transport_factory = fake.factory,
    on_exit = function(code, expected)
      exited = { code = code, expected = expected }
    end,
  })
  start_ready(client, fake)

  client:stop()
  assert_equal(1, fake.stop_calls)
  assert_equal(false, client.ready)
  assert_equal(nil, client.transport)
  wait_until(function()
    return exited ~= nil
  end)
  assert_equal({ code = 0, expected = true }, exited)
  assert_equal(nil, client:url())

  local request_error
  local id = client:request("thread/start", {}, function(_, err)
    request_error = err
  end)
  assert_equal(nil, id)
  assert_equal({ message = "Codex app-server is not ready" }, request_error)

  client:stop()
  assert_equal(1, fake.stop_calls, "stop should be idempotent after the transport is gone")
end)

test("fails a request immediately when the transport cannot send", function()
  local fake = new_fake_transport()
  local client = Client.new({ transport_factory = fake.factory })
  start_ready(client, fake)
  fake.send_ok = false
  local result
  client:request("thread/read", {}, function(_, err)
    result = err
  end)
  assert_equal({ message = "could not send the RPC message" }, result)
  assert_equal({}, client.pending, "a failed send must not leave a pending request")
end)

test("times out startup and requests with actionable errors", function()
  local startup_fake = new_fake_transport()
  local startup_result
  local startup_client = Client.new({
    transport_factory = startup_fake.factory,
    startup_timeout_ms = 10,
  })
  startup_client:start(function(ok, err)
    startup_result = { ok = ok, err = err }
  end)
  wait_until(function()
    return startup_result ~= nil
  end, "startup timeout did not release its waiter")
  assert_equal(false, startup_result.ok)
  assert_true(startup_result.err:find("startup timed out", 1, true) ~= nil)
  assert_equal(1, startup_fake.stop_calls)

  local request_fake = new_fake_transport()
  local request_client = Client.new({
    transport_factory = request_fake.factory,
    request_timeout_ms = 10,
  })
  start_ready(request_client, request_fake)
  local request_error
  request_client:request("thread/read", {}, function(_, err)
    request_error = err
  end)
  wait_until(function()
    return request_error ~= nil
  end, "request timeout did not release its callback")
  assert_true(request_error.message:find("request timed out", 1, true) ~= nil)
  assert_equal({}, request_client.pending)
  assert_equal(false, request_client.ready, "a timed-out request leaves the server outcome unknown")
  assert_equal(nil, request_client.transport, "the unknown generation must be discarded")
  assert_equal(1, request_fake.stop_calls)
end)

test("startup timeout invalidates its initialize request before restart", function()
  local fake = new_fake_transport()
  local first_result
  local client = Client.new({
    transport_factory = fake.factory,
    startup_timeout_ms = 10,
    request_timeout_ms = 100,
  })
  client:start(function(ok, err)
    first_result = { ok = ok, err = err }
  end)
  local first = fake.runs[1]
  first.on_line(vim.json.encode({ seal = { event = "ready", url = "ws://127.0.0.1:4700" } }))
  wait_until(function()
    return fake.sent[1] and fake.sent[1].method == "initialize"
  end)
  local stale_initialize = fake.sent[1]
  wait_until(function()
    return first_result ~= nil
  end, "startup timeout did not finish")
  assert_equal({}, client.pending, "the timed-out initialize request must not survive its generation")
  assert_equal(nil, client.transport)

  first.on_line(vim.json.encode({ id = stale_initialize.id, result = {} }))
  vim.wait(20)
  assert_equal(1, #fake.sent, "a just-late handshake from the stopped transport must be ignored")

  local restarted
  client:start(function(ok, err)
    restarted = { ok = ok, err = err }
  end)
  local second = fake.runs[2]
  second.on_line(vim.json.encode({ seal = { event = "ready", url = "ws://127.0.0.1:4701" } }))
  wait_until(function()
    return fake.sent[2] and fake.sent[2].method == "initialize"
  end)
  second.on_line(vim.json.encode({ id = fake.sent[2].id, result = {} }))
  wait_until(function()
    return restarted ~= nil
  end)
  assert_equal({ ok = true }, restarted)
  vim.wait(120)
  assert_true(client.ready, "the stale initialize timer must not stop the replacement transport")
  assert_true(client.transport == second.transport)
end)

test("late response after a request timeout cannot bind on a replacement generation", function()
  local fake = new_fake_transport()
  local exits = {}
  local client = Client.new({
    transport_factory = fake.factory,
    request_timeout_ms = 10,
    on_exit = function(code, expected)
      table.insert(exits, { code = code, expected = expected })
    end,
  })
  start_ready(client, fake)
  local first = fake.runs[1]
  local callbacks = 0
  local timeout_error
  local turn_id = client:request("turn/start", {}, function(_, err)
    callbacks = callbacks + 1
    timeout_error = err
  end)
  wait_until(function()
    return timeout_error ~= nil
  end)
  assert_equal(1, callbacks)
  assert_equal({ { code = 0, expected = true } }, exits,
    "the client should deliberately retire the desynchronized generation")

  first.on_line(vim.json.encode({ id = turn_id, result = { turn = { id = "late-turn" } } }))
  vim.wait(20)
  assert_equal(1, callbacks, "the late acknowledgement must remain detached")

  local restarted
  client:start(function(ok, err)
    restarted = { ok = ok, err = err }
  end)
  local second = fake.runs[2]
  second.on_line(vim.json.encode({ seal = { event = "ready", url = "ws://127.0.0.1:4800" } }))
  wait_until(function()
    return fake.sent[#fake.sent] and fake.sent[#fake.sent].method == "initialize"
  end)
  local initialize = fake.sent[#fake.sent]
  second.on_line(vim.json.encode({ id = initialize.id, result = {} }))
  wait_until(function()
    return restarted ~= nil
  end)
  assert_equal({ ok = true }, restarted)
  assert_true(client.transport == second.transport)
end)

test("rejects invalid UTF-8 before it reaches the shared transport", function()
  local fake = new_fake_transport()
  local client = Client.new({ transport_factory = fake.factory })
  start_ready(client, fake)
  local sent_before = #fake.sent
  local request_error
  client:request("turn/start", { input = string.char(255) }, function(_, err)
    request_error = err
  end)
  assert_true(request_error and request_error.message:find("valid UTF-8", 1, true) ~= nil)
  assert_equal(sent_before, #fake.sent, "invalid UTF-8 must not be written to the bridge")
end)

test("ignores an old transport exit after restart", function()
  local fake = new_fake_transport()
  local client = Client.new({ transport_factory = fake.factory })
  start_ready(client, fake)
  local first = fake.runs[1]
  client:stop()

  local restarted
  client:start(function(ok, err)
    restarted = { ok = ok, err = err }
  end)
  local second = fake.runs[2]
  second.on_line(vim.json.encode({ seal = { event = "ready", url = "ws://127.0.0.1:4600" } }))
  wait_until(function()
    return fake.sent[#fake.sent] and fake.sent[#fake.sent].method == "initialize"
  end)
  local initialize = fake.sent[#fake.sent]
  second.on_line(vim.json.encode({ id = initialize.id, result = {} }))
  wait_until(function()
    return restarted ~= nil
  end)
  assert_equal({ ok = true }, restarted)

  first.on_exit(0, true)
  vim.wait(20)
  assert_true(client.ready, "a stale exit must not reset the restarted client")
  assert_true(client.transport == second.transport, "a stale exit must not discard the new transport")
  assert_equal("ws://127.0.0.1:4600", client:url())
end)

local failures = {}
for _, case in ipairs(tests) do
  local ok, err = xpcall(case.body, debug.traceback)
  if ok then
    print("ok - " .. case.name)
  else
    table.insert(failures, case.name .. "\n" .. err)
    print("not ok - " .. case.name)
  end
end

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n\n") .. "\n")
  vim.cmd("cquit 1")
else
  print(string.format("%d client tests passed", #tests))
  vim.cmd("qa!")
end
