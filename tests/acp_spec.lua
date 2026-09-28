local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local Acp = require("seal.acp")
local seal = require("seal")
local fixtures = {}
local tests = {}
local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")

local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function wait_for(predicate)
  assert(vim.wait(1000, predicate, 1), "timed out waiting for protocol activity")
end

local function test(name, body)
  table.insert(tests, { name = name, body = body })
end

local function fixture(opts)
  local f = { sent = {}, events = {}, requests = {}, errors = {}, stopped = 0 }
  opts = vim.tbl_extend("force", {
    on_notification = function(method, params)
      table.insert(f.events, { method = method, params = params })
    end,
    on_server_request = function(request)
      table.insert(f.requests, request)
    end,
    on_error = function(message)
      table.insert(f.errors, message)
    end,
  }, opts or {})
  function f.factory(_, on_line, on_exit)
    f.on_line, f.on_exit = on_line, on_exit
    return {
      send = function(_, line)
        local message = vim.json.decode(line)
        equal("2.0", message.jsonrpc)
        table.insert(f.sent, message)
        return true
      end,
      stop = function()
        f.stopped = f.stopped + 1
      end,
    }
  end
  opts.transport_factory = f.factory
  f.client = Acp.new(opts)
  function f:emit(message)
    self.client.rpc:_feed(message)
  end
  function f:last(method)
    for i = #self.sent, 1, -1 do
      if self.sent[i].method == method then
        return self.sent[i]
      end
    end
  end
  function f:reply(request, result, err)
    self:emit({ id = request.id, result = result, error = err })
  end
  function f:start()
    local ready
    self.client:start(function(ok, err)
      assert(ok, err)
      ready = true
    end)
    local init = assert(self:last("initialize"))
    equal(1, init.params.protocolVersion)
    equal(false, init.params.clientCapabilities.terminal)
    equal(false, init.params.clientCapabilities.fs.writeTextFile)
    self:reply(init, { protocolVersion = 1, agentCapabilities = {} })
    assert(ready)
  end
  function f:session(id)
    local thread
    self.client:request("thread/start", { cwd = project }, function(result, err)
      assert(result, vim.inspect(err))
      thread = result.thread
    end)
    local request = self:last("session/new")
    equal(project, request.params.cwd)
    self:reply(request, { sessionId = id or "s1" })
    equal(id or "s1", thread.id)
    return thread.id
  end
  function f:prompt(params)
    local turn
    params = vim.tbl_extend("force", {
      threadId = "s1",
      input = { { type = "text", text = "hello" } },
    }, params or {})
    self.client:request("turn/start", params, function(result, err)
      assert(result, vim.inspect(err))
      turn = result.turn.id
    end)
    return assert(turn), assert(self:last("session/prompt"))
  end
  function f:update(update, session_id)
    self:emit({ method = "session/update", params = { sessionId = session_id or "s1", update = update } })
  end
  function f:permission(id, tool, options, session_id)
    self:emit({ id = id, method = "session/request_permission", params = {
      sessionId = session_id or "s1",
      toolCall = tool,
      options = options or {
        { optionId = "always", kind = "allow_always" },
        { optionId = "once", kind = "allow_once" },
        { optionId = "no", kind = "reject_once" },
      },
    } })
  end
  function f:decide(decision)
    return self.client:respond(self.requests[#self.requests].id, { decision = decision })
  end
  table.insert(fixtures, f)
  return f
end

local function running(opts)
  local f = fixture(opts)
  f:start()
  f:session()
  local turn, prompt = f:prompt()
  return f, turn, prompt
end

test("negotiates ACP over JSON-RPC without bridge readiness or initialized notification", function()
  local f = fixture()
  f:start()
  equal(1, #f.sent)
  f:session()
  equal(nil, f.client:url())
end)

test("rejects unsupported protocol versions and authentication methods", function()
  for _, opts in ipairs({ {}, { acp = { auth_method = "missing" } } }) do
    local f = fixture(opts)
    local failure
    f.client:start(function(ok, err)
      assert(not ok)
      failure = err
    end)
    f:reply(f:last("initialize"), { protocolVersion = opts.acp and 1 or 99, authMethods = {} })
    assert(failure)
    equal(1, f.stopped)
  end
end)

test("authenticates only with an explicitly selected advertised method", function()
  local f = fixture({ acp = { auth_method = "gemini-api-key" } })
  local ready
  f.client:start(function(ok) ready = ok end)
  f:reply(f:last("initialize"), { protocolVersion = 1, authMethods = { { id = "gemini-api-key" } } })
  equal(nil, ready)
  local auth = f:last("authenticate")
  equal("gemini-api-key", auth.params.methodId)
  f:reply(auth, {})
  equal(true, ready)
end)

test("keeps long prompts open and assembles only agent text in the transcript", function()
  local f = fixture({ request_timeout_ms = 10 })
  f:start()
  f:session()
  local _, prompt = f:prompt({ additionalContext = { ["seal.editor"] = { value = "private editor context" } } })
  equal(2, #prompt.params.prompt)
  vim.wait(30, function() return false end, 1)
  equal(true, f.client.rpc.ready)
  f:update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Hel" } })
  f:update({ sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "hidden" } })
  f:update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "lo" } })
  f:reply(prompt, { stopReason = "end_turn" })
  local history
  f.client:request("thread/read", { threadId = "s1", includeTurns = true }, function(result) history = result.thread end)
  equal("Hello", history.turns[1].items[2].text)
  equal(1, #history.turns[1].items[1].content)
  equal("completed", history.turns[1].status)
  assert(table.concat(require("seal.chat").render(history), "\n"):find("## Gemini", 1, true))
end)

test("adapts declaration text and declines all its permission requests", function()
  local f = fixture()
  f:start()
  f:session()
  local _, prompt = f:prompt({ outputSchema = { type = "object" } })
  f:permission(80, { toolCallId = "edit", kind = "edit" })
  equal("cancelled", f.sent[#f.sent].result.outcome.outcome)
  equal(0, #f.requests)
  f:update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "local answer = 42" } })
  f:reply(prompt, { stopReason = "end_turn" })
  equal({ code = "local answer = 42" }, vim.json.decode(f.events[#f.events - 1].params.item.text))
end)

test("reviews complete diffs even when permission precedes the tool notification", function()
  local f = running()
  local path = project .. "/review.txt"
  vim.fn.writefile({ "old" }, path)
  f:permission("p1", { toolCallId = "edit", kind = "edit", content = {
    { type = "diff", path = path, oldText = "old\n", newText = "new\n" },
  } })
  equal("item/fileChange/requestApproval", f.requests[1].method)
  assert(f.events[#f.events].params.item.changes[1].diff:find("+new", 1, true))
  assert(f:decide("accept"))
  equal({ outcome = "selected", optionId = "once" }, f.sent[#f.sent].result.outcome)
  f:update({ sessionUpdate = "tool_call_update", toolCallId = "edit", status = "completed" })
  equal("fileChange", f.events[#f.events].params.item.type)
end)

test("merges partial tool updates and never substitutes permanent approval", function()
  local f = running()
  f:update({ sessionUpdate = "tool_call", toolCallId = "cmd", kind = "execute", title = "run tests" })
  f:permission(5, { toolCallId = "cmd" }, { { optionId = "always", kind = "allow_always" } })
  equal("run tests", f.requests[1].params.command)
  equal({ "decline", "cancel" }, f.requests[1].params.availableDecisions)
  assert(not f:decide("accept"))
  assert(f:decide("decline"))
  equal("cancelled", f.sent[#f.sent].result.outcome.outcome)
end)

test("refuses stale full-file replacements after a local save", function()
  local f = running()
  local path = project .. "/stale.txt"
  vim.fn.writefile({ "old" }, path)
  f:permission(6, { toolCallId = "edit", kind = "edit", content = {
    { type = "diff", path = path, oldText = "old\n", newText = "new\n" },
  } })
  vim.fn.writefile({ "local work" }, path)
  assert(not f:decide("accept"))
  equal("local work", vim.fn.readfile(path)[1])
  assert(f:decide("decline"))
end)

test("rejects unsupported client file and terminal operations", function()
  local f = running()
  for _, method in ipairs({ "fs/write_text_file", "fs/read_text_file", "terminal/create" }) do
    f:emit({ id = 20, method = method, params = { sessionId = "s1" } })
    equal(-32601, f.sent[#f.sent].error.code)
  end
end)

test("accepts Gemini file creation with either null or empty original text", function()
  for i, old in ipairs({ vim.NIL, "" }) do
    local f = running()
    local path = project .. "/new-" .. i .. ".txt"
    f:permission(8, { toolCallId = "create", kind = "edit", content = {
      { type = "diff", path = path, oldText = old, newText = "created\n" },
    } })
    equal("add", f.events[#f.events].params.item.changes[1].kind)
    assert(f:decide("accept"))
    equal("once", f.sent[#f.sent].result.outcome.optionId)
  end
end)

test("does not turn an invalid diff into a command approval", function()
  local f = running()
  f:permission(9, { toolCallId = "edit", title = "write file", content = {
    { type = "diff", path = "relative.txt", newText = "unsafe" },
  } })
  equal("item/fileChange/requestApproval", f.requests[#f.requests].method)
  assert(not f:decide("accept"))
  assert(f:decide("decline"))
end)

test("gives reused ACP request IDs distinct review identities", function()
  local f = running()
  f:permission(10, { toolCallId = "a", kind = "execute", title = "first" })
  local first = f.requests[#f.requests].id
  assert(f:decide("decline"))
  equal(10, f.sent[#f.sent].id)
  f:permission(10, { toolCallId = "b", kind = "execute", title = "second" })
  assert(first ~= f.requests[#f.requests].id)
  assert(not f.client:respond(first, { decision = "accept" }))
  assert(f:decide("decline"))
  equal(10, f.sent[#f.sent].id)
end)

test("declines permissions if the caller has no approval UI", function()
  local f = running({ on_server_request = false })
  f:permission(11, { toolCallId = "cmd", kind = "execute", title = "run" })
  equal("no", f.sent[#f.sent].result.outcome.optionId)
  equal({}, f.client.permissions)
end)

test("reports missing executables and rejects shell command strings", function()
  local ok = pcall(Acp.new, { acp = { command = "gemini --acp" } })
  equal(false, ok)
  local client = Acp.new({ acp = { command = { "/no/such/seal-acp-agent" } } })
  local failure
  client:start(function(ready, err)
    equal(false, ready)
    failure = err
  end)
  assert(failure)
  equal(false, client.rpc.starting)
  client:stop()
end)

test("keeps the session busy until cancellation is acknowledged", function()
  local f, turn, prompt = running()
  f:permission(7, { toolCallId = "cmd", kind = "execute", title = "run" })
  f.client:request("turn/interrupt", { threadId = "s1", turnId = turn }, function(result) assert(result) end)
  assert(f:last("session/cancel"))
  equal(nil, f:last("session/cancel").id)
  equal({}, f.client.permissions)
  local rejected
  f.client:request("turn/start", { threadId = "s1" }, function(_, err) rejected = err end)
  assert(rejected.message:find("active turn", 1, true))
  f:reply(prompt, { stopReason = "cancelled" })
  equal("interrupted", f.events[#f.events].params.turn.status)
  f:prompt()
end)

test("retires an agent that ignores cancellation and discards late updates", function()
  local f, turn = running({ request_timeout_ms = 10 })
  f.client:request("turn/interrupt", { threadId = "s1", turnId = turn })
  wait_for(function() return f.stopped == 1 end)
  equal(false, f.client.rpc.ready)
  equal({}, f.client.sessions)
  local count = #f.events
  f:update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "late" } })
  equal(count, #f.events)
end)

test("routes concurrent project sessions independently", function()
  local f, _, first = running()
  f:session("s2")
  local _, second = f:prompt({ threadId = "s2" })
  f:update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "second" } }, "s2")
  f:reply(second, { stopReason = "end_turn" })
  equal("s2", f.events[#f.events].params.threadId)
  assert(f.client.sessions.s1.active)
  f:reply(first, nil, { message = "model unavailable" })
  equal("failed", f.events[#f.events].params.turn.status)
  equal("model unavailable", f.events[#f.events].params.turn.error.message)
end)

local function editor_fixture()
  local f = fixture()
  seal.setup({
    backend = "acp",
    transport_factory = f.factory,
    root = function() return project end,
    notify = function(message, level)
      if level == vim.log.levels.ERROR then table.insert(f.errors, message) end
    end,
    keymaps = { prompt = false, chat = false },
  })
  vim.cmd("enew!")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "", "" })
  function f:connect_editor()
    self.client = seal._state.client
    self:reply(self:last("initialize"), { protocolVersion = 1 })
    self:reply(self:last("session/new"), { sessionId = "s1" })
  end
  return f
end

test("queues two editor declarations on one session and accepts inline previews", function()
  local f = editor_fixture()
  assert(seal.submit("fun: define first"))
  f:connect_editor()
  local first = assert(f:last("session/prompt"))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(seal.submit("fun: define second"))
  equal(first.id, f:last("session/prompt").id)
  f:update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "local function first() end" } })
  f:reply(first, { stopReason = "end_turn" })
  wait_for(function() return f:last("session/prompt").id ~= first.id end)
  local second = f:last("session/prompt")
  equal("s1", second.params.sessionId)
  f:update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "local function second() end" } })
  f:reply(second, { stopReason = "end_turn" })
  wait_for(function() return seal.status().preview_count == 2 end)
  assert(seal.accept())
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert(seal.accept())
  local source = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(source:find("first", 1, true) and source:find("second", 1, true))
  equal({}, f.errors)
end)

test("bounded editor edits stop only after the reviewed tool completes", function()
  local f = editor_fixture()
  local path = project .. "/bounded.lua"
  vim.fn.writefile({ "local value = 1" }, path)
  vim.cmd.edit(path)
  assert(seal.submit("targeted: set value to 2"))
  f:connect_editor()
  local prompt = assert(f:last("session/prompt"))
  f:permission(80, { toolCallId = "edit", kind = "edit", content = {
    { type = "diff", path = path, oldText = "local value = 1\n", newText = "local value = 2\n" },
  } })
  equal(1, seal.status().pending_reviews)
  local review = next(seal._state.reviews) and select(2, next(seal._state.reviews))
  assert(review and review.view)
  vim.api.nvim_set_current_win(review.view.win)
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal("once", f.sent[#f.sent].result.outcome.optionId)
  equal(nil, f:last("session/cancel"))
  vim.fn.writefile({ "local value = 2" }, path)
  f:update({ sessionUpdate = "tool_call_update", toolCallId = "edit", status = "completed" })
  assert(f:last("session/cancel"))
  f:reply(prompt, { stopReason = "cancelled" })
  wait_for(function() return seal.status().running_count == 0 end)
  equal({}, f.errors)
end)

local failures = {}
for _, entry in ipairs(tests) do
  local ok, err = xpcall(entry.body, debug.traceback)
  seal.stop()
  for _, f in ipairs(fixtures) do f.client:stop() end
  fixtures = {}
  vim.wait(5, function() return false end, 1)
  if ok then
    io.stdout:write("ok - " .. entry.name .. "\n")
  else
    io.stdout:write("not ok - " .. entry.name .. "\n")
    table.insert(failures, entry.name .. "\n" .. tostring(err))
  end
end
vim.fn.delete(project, "rf")
if #failures > 0 then error(table.concat(failures, "\n\n")) end
io.stdout:write(string.format("%d ACP tests passed\n", #tests))
