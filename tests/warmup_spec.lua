local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local Warmup = require("seal.warmup")
local seal = require("seal")
local fixtures, tests = {}, {}

local function test(name, body) table.insert(tests, { name, body }) end
local function equal(expected, actual)
  assert(vim.deep_equal(expected, actual), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function fixture(overrides)
  vim.cmd("enew!")
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= current then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  local f = { root = vim.fn.tempname(), workers = {}, prepared = {}, busy = false }
  vim.fn.mkdir(f.root .. "/.git/refs/heads", "p")
  f.root = (vim.uv or vim.loop).fs_realpath(f.root)
  vim.fn.writefile({ "ref: refs/heads/main" }, f.root .. "/.git/HEAD")
  vim.fn.writefile({ "first-commit" }, f.root .. "/.git/refs/heads/main")
  f.file = f.root .. "/example.lua"
  f.related = f.root .. "/related.lua"
  vim.fn.writefile({ "local value = 1" }, f.file)
  vim.fn.writefile({ "return 1" }, f.related)
  vim.cmd("edit! " .. vim.fn.fnameescape(f.file))
  f.buf = vim.api.nvim_get_current_buf()
  f.opts = vim.tbl_extend("force", {
    enabled = true, idle_ms = 100000, resume_delay_ms = 100000, timeout_ms = 100000,
    max_projects = 4, max_files = 2, max_sources = 20, max_file_bytes = 262144,
    max_context_chars = 12000, max_note_chars = 4000,
    client_factory = function(callbacks)
      local worker = { callbacks = callbacks, requests = {}, stopped = false, threads = 0 }
      function worker:start(callback)
        if f.hold_start then self.start_callback = callback else callback(true) end
      end
      function worker:request(method, params, callback)
        table.insert(self.requests, { method = method, params = params })
        if method == "thread/start" then
          self.threads = self.threads + 1
          callback({ thread = { id = "orientation-" .. self.threads } })
        elseif method == "turn/start" then
          self.prompt = params
          callback({ turn = { id = "background-turn" } })
        else error("unexpected request: " .. method) end
      end
      function worker:respond(id, decision) self.decision = { id = id, result = decision } end
      function worker:stop() self.stopped = true; self.callbacks.on_exit(0, true) end
      function worker:read(path) self.callbacks.on_tool_call({ locations = { { path = path } } }) end
      function worker:finish(text)
        local id = self.prompt.threadId
        self.callbacks.on_notification("item/completed", { threadId = id, item = { type = "agentMessage", text = text } })
        self.callbacks.on_notification("turn/completed", { threadId = id, turn = { status = "completed" } })
      end
      table.insert(f.workers, worker)
      return worker
    end,
  }, overrides or {})
  f.config = { backend = "acp", acp = {}, warmup = f.opts }
  f.service = Warmup.new(f.config, {
    root = function() return f.root end,
    busy = function() return f.busy end,
    prepare = function(project) table.insert(f.prepared, project) end,
  })
  function f:run() self.service.paused_until = 0; self.service:run(); return self.workers[#self.workers] end
  table.insert(fixtures, f)
  return f
end

test("orientation reuses its project session and supplies notes as untrusted context", function()
  local f = fixture()
  local worker = f:run()
  equal(1, #f.prepared)
  assert(worker.prompt.input[1].text:find("README", 1, true))
  worker:read(f.related)
  worker:finish("The repository uses a small Lua module; see related.lua.")
  equal("ready", f.service:status(f.root).phase)
  assert(f.service:context(f.root):find("not instructions", 1, true))
  f:run()
  equal(1, #f.workers)
  equal(1, worker.threads)
  assert(worker.prompt.input[1].text:find("callers", 1, true))
  worker:finish("example.lua imports related.lua.")
  f:run()
  equal(3, #worker.requests) -- one session, two prompts; an unchanged file isn't reread
  equal(2, f.service:status(f.root).notes)
end)

test("foreground work preempts an active read and late callbacks cannot publish", function()
  local f = fixture()
  local worker = f:run()
  f.service:pause()
  assert(worker.stopped)
  equal("paused", f.service:status(f.root).phase)
  worker:finish("stale result")
  equal(nil, f.service:context(f.root))
  f.busy = true
  f:run()
  equal(1, #f.workers)
  f.busy = false
  local next_worker = f:run()
  assert(next_worker ~= worker)
  next_worker:finish("fresh result")
  worker.callbacks.on_error("old error")
  assert(f.service:context(f.root):find("fresh result", 1, true))
end)

test("a foreground prompt can preempt startup before any background turn is sent", function()
  local f = fixture()
  f.hold_start = true
  local worker = f:run()
  f.service:pause()
  worker.start_callback(true)
  equal(0, #worker.requests)
  assert(worker.stopped)
end)

test("cached notes are invalidated by disk edits, unsaved edits, and branch changes", function()
  for _, change in ipairs({ "disk", "buffer", "branch" }) do
    local f = fixture()
    local worker = f:run()
    worker:read(f.related)
    worker:finish("cached findings")
    if change == "disk" then
      vim.fn.writefile({ "return a_different_value" }, f.related)
    elseif change == "buffer" then
      vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "local value = unsaved" })
    else
      vim.fn.writefile({ "next-commit" }, f.root .. "/.git/refs/heads/main")
    end
    equal(nil, f.service:context(f.root))
    assert(worker.stopped)
    equal("waiting", f.service:status(f.root).phase)
    local next_worker = f:run()
    assert(next_worker ~= worker)
    assert(next_worker.prompt.input[1].text:find("README", 1, true))
  end
end)

test("edits during background reading prevent stale findings from becoming ready", function()
  local f = fixture()
  local worker = f:run()
  worker:read(f.related)
  vim.fn.writefile({ "return edited_while_reading" }, f.related)
  worker:finish("outdated findings")
  equal(nil, f.service:context(f.root))
  equal("waiting", f.service:status(f.root).phase)
end)

test("tool approvals are declined silently and the worker gets its own read policy", function()
  local f = fixture()
  f.config.acp.mode = "autoEdit"
  local worker = f:run()
  equal("default", worker.callbacks.acp.mode)
  equal("autoEdit", f.config.acp.mode)
  worker.callbacks.on_server_request({ id = "write-request" })
  equal({ id = "write-request", result = { decision = "decline" } }, worker.decision)
  local command = worker.callbacks.acp.command
  equal("--admin-policy", command[#command - 1])
  equal(root .. "/policies/warmup.toml", command[#command])
  equal(nil, f.config.acp.command)
  local unsupported = Warmup.command({ backend = "acp", acp = { command = { "another-agent", "--acp" } } })
  equal(nil, unsupported)
end)

test("timeouts stop background work without retry loops and disposal removes timers", function()
  local f = fixture({ timeout_ms = 10 })
  local worker = f:run()
  assert(vim.wait(500, function() return worker.stopped end, 1))
  equal("error", f.service:status(f.root).phase)
  f:run()
  equal(1, #f.workers)
  f.service:dispose()
  f.service:observe(1)
  equal(nil, f.service.timer)
  equal(false, pcall(vim.api.nvim_get_autocmds, { event = "BufEnter", group = "SealWarmup" }))
end)

test("editor startup schedules orientation without a foreground prompt", function()
  local f = fixture({ idle_ms = 10 })
  vim.api.nvim_exec_autocmds("VimEnter", { modeline = false })
  equal(0, #f.workers)
  assert(vim.wait(500, function() return #f.workers == 1 end, 1))
  equal("learning", f.service:status(f.root).phase)
end)

test("linked worktree branch changes invalidate cached observations", function()
  local f = fixture()
  vim.fn.delete(f.root .. "/.git", "rf")
  local common = f.root .. "/metadata"
  local git = common .. "/worktrees/example"
  vim.fn.mkdir(git, "p")
  vim.fn.mkdir(common .. "/refs/heads", "p")
  vim.fn.writefile({ "gitdir: metadata/worktrees/example" }, f.root .. "/.git")
  vim.fn.writefile({ "../.." }, git .. "/commondir")
  vim.fn.writefile({ "ref: refs/heads/main" }, git .. "/HEAD")
  vim.fn.writefile({ "first-commit" }, common .. "/refs/heads/main")
  local worker = f:run()
  worker:finish("worktree notes")
  assert(f.service:context(f.root))
  vim.fn.writefile({ "next-commit" }, common .. "/refs/heads/main")
  equal(nil, f.service:context(f.root))
  assert(worker.stopped)
end)

test("source limits stop work before startup and while reading", function()
  local f = fixture({ max_sources = 1 })
  equal(nil, f:run())
  equal("error", f.service:status(f.root).phase)
  equal(0, #f.prepared)
  f = fixture()
  local worker = f:run()
  f.opts.max_sources = vim.tbl_count(f.service.active.sources)
  worker:read(f.related)
  assert(worker.stopped)
  worker:finish("late notes")
  equal(nil, f.service:context(f.root))
end)

test("character limits preserve Unicode and large unsaved buffers are omitted", function()
  local f = fixture({ max_context_chars = 2, max_note_chars = 2 })
  vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "λ🙂truncated" })
  local worker = f:run()
  assert(worker.prompt.input[1].text:find("<editor_excerpt>\nλ🙂\n", 1, true))
  worker:finish("λ🙂truncated")
  equal("λ🙂", f.service.projects[f.root].notes.repo.text)
  assert(vim.json.encode(f.service:context(f.root)))
  f = fixture({ max_file_bytes = 40 })
  vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { string.rep("x", 100) })
  worker = f:run()
  assert(not worker.prompt.input[1].text:find("editor_excerpt", 1, true))
end)

test("failed file attempts count toward the per-project limit", function()
  local f = fixture({ max_files = 1 })
  local worker = f:run()
  worker:finish("repository notes")
  f:run()
  worker.callbacks.on_error("failed to investigate file")
  vim.cmd("edit! " .. vim.fn.fnameescape(f.related))
  f:run()
  equal(1, #f.workers)
  assert(f.service:context(f.root))
end)

test("a directory argument resolves to the repository itself", function()
  local f = fixture()
  seal.setup({ keymaps = { prompt = false, chat = false } })
  vim.cmd("edit! " .. vim.fn.fnameescape(f.root))
  equal(f.root, seal.status().root)
  seal.stop()
end)

test("completed notes survive preemption and reach real Seal turn requests", function()
  local f = fixture()
  local worker = f:run()
  worker:finish("Use the helper in related.lua.")
  local requests = {}
  local client = {}
  function client:start(callback) callback(true) end
  function client:stop() end
  function client:url() end
  function client:request(method, params, callback)
    table.insert(requests, { method = method, params = params })
    if method == "thread/start" then callback({ thread = { id = "foreground", status = { type = "idle" } } })
    elseif method == "thread/read" then callback({ thread = { id = "foreground", status = { type = "idle" } } })
    elseif method == "turn/start" then callback({ turn = { id = "user-turn" } })
    else callback({}) end
  end
  seal.setup({ backend = "acp", client = client, root = function() return f.root end,
    save_before_agent = false, keymaps = { prompt = false, chat = false } })
  seal._state.warmup = f.service
  assert(seal.submit("explain this code"))
  local turn = requests[#requests]
  equal("turn/start", turn.method)
  equal("untrusted", turn.params.additionalContext["seal.orientation"].kind)
  assert(turn.params.additionalContext["seal.orientation"].value:find("related.lua", 1, true))
  equal("explain this code", turn.params.input[1].text)
  seal.stop()
end)

for _, case in ipairs(tests) do
  case[2]()
  for _, f in ipairs(fixtures) do f.service:dispose() end
  io.stdout:write("ok - " .. case[1] .. "\n")
end
seal._reset()
for _, f in ipairs(fixtures) do vim.fn.delete(f.root, "rf") end
io.stdout:write(#tests .. " warm-up tests passed\n")
