local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local Alto = require("seal.alto")
local seal = require("seal")
local uv = vim.uv or vim.loop
local socket_path = "/tmp/seal-alto-spec-" .. uv.os_getpid() .. ".sock"
local server, peers, calls, handler
local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end
local function wait_for(predicate)
  assert(vim.wait(1000, predicate, 1), "timed out")
end
local function start(on_request)
  peers, calls, handler = {}, {}, on_request
  server = uv.new_pipe(false)
  assert(server:bind(socket_path))
  server:listen(16, function(err)
    assert(not err, err)
    local peer = uv.new_pipe(false)
    server:accept(peer)
    table.insert(peers, peer)
    local buffer = ""
    peer:read_start(function(read_err, chunk)
      assert(not read_err, read_err)
      if not chunk then return end
      buffer = buffer .. chunk
      if not buffer:find("\n", 1, true) then return end
      peer:read_stop()
      local request = vim.json.decode(buffer)
      table.insert(calls, request)
      handler(peer, request)
    end)
  end)
end
local function stop()
  Alto.stop()
  seal.stop()
  if server and not server:is_closing() then server:close() end
  for _, peer in ipairs(peers or {}) do if not peer:is_closing() then peer:close() end end
  uv.fs_unlink(socket_path)
  vim.wait(5, function() return false end, 1)
end
local tests = {
  { "sends a framed request and handles a split reply", function()
    start(function(peer, request)
      equal(1, request.version)
      peer:write('{"ok":true,')
      peer:write('"target":{"title":"Example"}}\n')
    end)
    local reply
    Alto.request({ action = "send", text = "hello", context = "code", mode = "queue" }, { socket = socket_path }, function(value, err)
      assert(not err, err)
      reply = value
    end)
    wait_for(function() return reply end)
    equal("Example", reply.target.title)
    equal("hello", calls[1].text)
  end },
  { "reports an unavailable Alto plugin", function()
    local failure
    Alto.request({ action = "status" }, { socket = socket_path .. ".missing" }, function(_, err) failure = err end)
    wait_for(function() return failure end)
    assert(failure:find("Could not connect", 1, true))
  end },
  { "times out without retrying an uncertain delivery", function()
    start(function() end)
    local failure
    Alto.request({ action = "send", text = "hello", context = "", mode = "queue" }, { socket = socket_path, timeout_ms = 20 }, function(_, err) failure = err end)
    wait_for(function() return failure end)
    assert(failure:find("before retrying", 1, true))
    equal(1, #calls)
  end },
  { "closing pending connections completes each callback once", function()
    start(function() end)
    local completed = 0
    Alto.request({ action = "status" }, { socket = socket_path }, function() completed = completed + 1 end)
    wait_for(function() return #calls == 1 end)
    Alto.stop()
    wait_for(function() return completed == 1 end)
    Alto.stop()
    equal(1, completed)
  end },
  { "hands off the originating buffer and selection without starting an agent", function()
    start(function(peer)
      peer:write('{"ok":true,"target":{"title":"Alto chat"}}\n')
    end)
    local notifications = {}
    seal.setup({ alto = { socket = socket_path }, root = function() return root end,
      notify = function(message) table.insert(notifications, message) end,
      keymaps = { prompt = false, chat = false },
    })
    vim.cmd("enew!")
    vim.bo.filetype = "lua"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local answer = 42", "print(answer)" })
    seal.alto("explain this", { range = 2, line1 = 1, line2 = 1, steer = true })
    wait_for(function() return #notifications > 0 end)
    equal("steer", calls[1].mode)
    assert(calls[1].context:find("<selection>\nlocal answer = 42\n</selection>", 1, true))
    assert(calls[1].context:find("unsaved changes", 1, true))
    equal(nil, seal._state.client)
    equal(true, vim.bo.modified)
    assert(notifications[1]:find("Alto chat", 1, true))
  end },
}
local failures = {}
for _, test in ipairs(tests) do
  local ok, err = xpcall(test[2], debug.traceback)
  stop()
  io.stdout:write((ok and "ok - " or "not ok - ") .. test[1] .. "\n")
  if not ok then table.insert(failures, tostring(err)) end
end
assert(#failures == 0, table.concat(failures, "\n"))
io.stdout:write(#tests .. " Alto handoff tests passed\n")
