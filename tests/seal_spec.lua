local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local seal = require("seal")

local function fail(message)
  error(message, 2)
end

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(value, message)
  if not value then
    fail(message)
  end
end

local function request(fake, method, index)
  local matches = {}
  for _, item in ipairs(fake.requests) do
    if item.method == method then
      table.insert(matches, item)
    end
  end
  return matches[index or #matches]
end

local function fake_client()
  local fake = {
    requests = {},
    responses = {},
    stopped = false,
    thread_start_count = 0,
  }

  function fake:start(callback)
    callback(true)
  end

  function fake:url()
    return "ws://127.0.0.1:4567"
  end

  function fake:respond(id, result)
    table.insert(self.responses, { id = id, result = result })
  end

  function fake:respond_error(id, code, message)
    table.insert(self.responses, { id = id, error = { code = code, message = message } })
  end

  function fake:stop()
    self.stopped = true
  end

  function fake:request(method, params, callback)
    table.insert(self.requests, { method = method, params = params })
    if method == "thread/start" then
      self.thread_start_count = self.thread_start_count + 1
      local id = self.thread_start_count == 1 and "main-thread" or "empty-fork"
      callback({
        thread = { id = id, status = { type = "idle" } },
        model = "gpt-test",
        modelProvider = "openai",
        reasoningEffort = "high",
        serviceTier = "fast",
      })
    elseif method == "thread/resume" then
      callback(nil, { message = "missing" })
    elseif method == "thread/read" then
      callback({ thread = { id = params.threadId, status = self.thread_status or { type = "idle" } } })
    elseif method == "thread/fork" then
      if self.fork_error then
        callback(nil, { message = "no rollout found for thread id" })
      else
        callback({ thread = { id = "fork-thread", status = { type = "idle" }, ephemeral = true } })
      end
    elseif method == "turn/start" then
      local declaration = params.threadId == "fork-thread" or params.threadId == "empty-fork"
      callback({ turn = { id = declaration and "fork-turn" or "main-turn" } })
    else
      callback({})
    end
  end

  return fake
end

local notifications
local terminals
local fake
local buffer_sequence = 0

local function setup(lines, overrides)
  seal._reset()
  notifications = {}
  terminals = {}
  fake = fake_client()
  local options = {
    client = fake,
    save_before_agent = false,
    root = function()
      return "/tmp/seal-project"
    end,
    terminal = function(spec)
      table.insert(terminals, spec)
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    keymaps = { prompt = false, terminal = false },
  }
  seal.setup(vim.tbl_deep_extend("force", options, overrides or {}))
  vim.cmd("enew!")
  buffer_sequence = buffer_sequence + 1
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_name(0, string.format("/tmp/seal-project/example-%d.lua", buffer_sequence))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or { "" })
  local undolevels = vim.bo.undolevels
  vim.bo.undolevels = -1
  vim.bo.undolevels = undolevels
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local tests = {}

function tests.routes_only_known_prefixes()
  setup()
  equal(seal._route(" fun: load it "), {
    mode = "declaration",
    kind = "function",
    prompt = "load it",
    original = "fun: load it",
  }, "fun prefix should select declaration mode")
  equal(seal._route("TYPE: durable state").kind, "type", "prefixes should be case insensitive")
  equal(seal._route("fix: this bug").mode, "agent", "unknown colon prefixes should remain freeform")
  equal(seal._route("https://example.com").mode, "agent", "URLs should remain freeform")
  equal(seal._route("  preserve me  ").prompt, "  preserve me  ", "freeform whitespace should be preserved")
end

function tests.normalizes_nested_indentation()
  setup()
  equal(seal._normalize_code("    function x()\n      return 1\n    end", "  "), {
    "  function x()",
    "    return 1",
    "  end",
  }, "model indentation should become relative to the insertion scope")
  equal(seal._normalize_code("```lua\nlocal x = 1\n```", ""), { "local x = 1" }, "outer fence should be removed")
end

function tests.large_context_keeps_cursor_line()
  setup()
  local text, first, last = seal._excerpt({ string.rep("a", 50), string.rep("b", 50), "CURSOR" }, 3, 20)
  truthy(text:find("CURSOR", 1, true), "excerpt must always include the cursor line")
  equal({ first, last }, { 3, 3 }, "oversized surrounding lines should not displace the cursor")
end

function tests.visual_selection_shares_the_context_budget()
  setup({ string.rep("a", 30), string.rep("b", 30), string.rep("c", 30) }, { max_context_chars = 20 })
  local snapshot = seal._capture({ range = 2, line1 = 1, line2 = 3 })
  local context_chars = vim.fn.strchars(snapshot.excerpt) + vim.fn.strchars(snapshot.selection)
  truthy(context_chars <= 20, "selection and excerpt must share max_context_chars")
  truthy(snapshot.selection:sub(-#"…") == "…", "an oversized visual selection should be truncated")
end

function tests.freeform_uses_main_thread_unchanged()
  setup({ "local value = 1" })
  truthy(seal.submit("explain this: precisely"), "freeform prompt should submit")
  local turn = request(fake, "turn/start")
  equal(turn.params.threadId, "main-thread", "freeform prompt should use the persistent thread")
  equal(turn.params.input[1].text, "explain this: precisely", "freeform prompt text must be unchanged")
  truthy(turn.params.outputSchema == nil, "freeform prompt must not constrain output")
  truthy(turn.params.additionalContext["seal.editor"].value:find("local value = 1", 1, true), "editor context should be attached")
  equal(turn.params.additionalContext["seal.editor"].kind, "untrusted", "repository text must stay outside the developer role")
  equal(#terminals, 1, "freeform prompt should open the terminal")
  equal(terminals[1].command, {
    "codex",
    "resume",
    "--remote",
    "ws://127.0.0.1:4567",
    "main-thread",
  }, "terminal must attach to the live app-server thread")
end

function tests.freeform_steers_an_active_turn()
  setup({ "local value = 1" })
  seal.submit("first prompt")
  fake.thread_status = { type = "active", activeFlags = {} }
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "active-turn", status = "inProgress" },
  })
  seal.submit("follow up exactly")
  local steer = request(fake, "turn/steer")
  equal(steer.params.threadId, "main-thread", "follow-up should steer the existing thread")
  equal(steer.params.expectedTurnId, "active-turn", "steer should guard the active turn id")
  equal(steer.params.input[1].text, "follow up exactly", "steered prompt must remain unchanged")
end

function tests.declaration_waits_for_active_main_turn()
  setup({ "" })
  seal.submit("first prompt")
  fake.thread_status = { type = "active", activeFlags = {} }
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "active-turn", status = "inProgress" },
  })
  seal.submit("fun: wait for consistency")
  truthy(request(fake, "thread/fork") == nil, "declaration must not fork an in-progress transcript")
  equal(terminals[#terminals].thread_id, "main-thread", "busy declaration should focus the owning terminal")
end

function tests.declaration_uses_safe_ephemeral_fork()
  setup({ "  " })
  truthy(seal.submit("fun: load the durable state"), "declaration prompt should submit")
  local fork = request(fake, "thread/fork")
  equal(fork.params.threadId, "main-thread", "fork should copy the persistent chat")
  equal(fork.params.ephemeral, true, "declaration fork should be ephemeral")
  equal(fork.params.sandbox, "read-only", "declaration fork should be read-only")
  equal(fork.params.approvalPolicy, "never", "declaration fork must not wait for approvals")
  equal(fork.params.excludeTurns, true, "fork response should omit copied transcript payloads")
  equal(fork.params.model, "gpt-test", "fork should inherit the main thread model")
  equal(fork.params.config.model_reasoning_effort, "high", "fork should inherit reasoning effort")
  truthy(fork.params.developerInstructions == nil, "fork should preserve the main thread's developer configuration")

  local turn = request(fake, "turn/start")
  equal(turn.params.threadId, "fork-thread", "declaration should run on the fork")
  truthy(turn.params.input[1].text:find("exactly one function", 1, true), "turn should carry the declaration contract")
  truthy(turn.params.input[1].text:find("load the durable state", 1, true), "turn should carry the user's intent")
  equal(turn.params.outputSchema.required, { "code" }, "declaration should require structured code")
  equal(#terminals, 0, "declaration mode should stay in the editor")
end

function tests.first_declaration_handles_empty_main_thread()
  setup({ "" })
  fake.fork_error = true
  seal.submit("type: cached value")
  local starts = {}
  for _, item in ipairs(fake.requests) do
    if item.method == "thread/start" then
      table.insert(starts, item)
    end
  end
  equal(#starts, 2, "an empty main thread should fall back to a new declaration thread")
  equal(starts[2].params.ephemeral, true, "fallback declaration thread should be ephemeral")
  equal(starts[2].params.sandbox, "read-only", "fallback declaration thread should be read-only")
  equal(request(fake, "turn/start").params.threadId, "empty-fork", "declaration should run on the fallback thread")
end

function tests.thread_setting_changes_flow_into_forks()
  setup({ "" })
  seal.submit("establish the main thread")
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      model = "gpt-updated",
      modelProvider = "openai",
      serviceTier = "priority",
      effort = "ultra",
      summary = "detailed",
      personality = "pragmatic",
    },
  })
  seal.submit("fun: inherit settings")
  local fork = request(fake, "thread/fork")
  equal(fork.params.model, "gpt-updated", "fork should use the current TUI model")
  equal(fork.params.serviceTier, "priority", "fork should use the current service tier")
  equal(fork.params.config.model_reasoning_effort, "ultra", "fork should use the current effort")
  equal(fork.params.config.model_reasoning_summary, "detailed", "fork should use the current summary mode")
  equal(fork.params.config.personality, "pragmatic", "fork should use the current personality")
end

function tests.null_thread_settings_are_omitted_from_forks()
  setup({ "" })
  seal.submit("establish the main thread")
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      model = "gpt-updated",
      modelProvider = "openai",
      serviceTier = vim.NIL,
      effort = vim.NIL,
      summary = vim.NIL,
      personality = vim.NIL,
    },
  })
  seal.submit("fun: null-safe settings")
  local fork = request(fake, "thread/fork")
  truthy(fork.params.config == nil, "JSON null settings must not become invalid config overrides")
  truthy(fork.params.serviceTier == nil, "null service tier should be omitted")
end

function tests.server_request_opens_owning_project_terminal()
  setup({ "" })
  seal._state.live["/tmp/project-a"] = { root = "/tmp/project-a", thread_id = "thread-a" }
  seal._state.live["/tmp/project-b"] = { root = "/tmp/project-b", thread_id = "thread-b" }
  seal._server_request({
    id = 41,
    method = "item/commandExecution/requestApproval",
    params = { threadId = "thread-a" },
  })
  equal(terminals[#terminals].cwd, "/tmp/project-a", "approval should open the terminal for its own thread")
  equal(terminals[#terminals].thread_id, "thread-a", "approval should attach the requesting thread")
end

function tests.superseded_fork_is_unsubscribed()
  setup({ "" })
  local original_request = fake.request
  local held_fork
  function fake:request(method, params, callback)
    if method == "thread/fork" and not held_fork then
      table.insert(self.requests, { method = method, params = params })
      held_fork = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: first")
  seal.submit("fun: second")
  held_fork({ thread = { id = "superseded-fork", ephemeral = true } })
  local unsubscribe = request(fake, "thread/unsubscribe")
  equal(unsubscribe.params.threadId, "superseded-fork", "superseded fork should be detached")
end

function tests.new_thread_interrupts_and_detaches_old_thread()
  setup({ "" })
  seal.submit("first prompt")
  seal._notification("thread/status/changed", {
    threadId = "main-thread",
    status = { type = "active", activeFlags = {} },
  })
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "active-turn", status = "inProgress" },
  })
  seal.new_thread()
  equal(request(fake, "turn/interrupt").params.turnId, "active-turn", "new thread should interrupt old work")
  equal(request(fake, "thread/unsubscribe").params.threadId, "main-thread", "new thread should detach the old session")
  equal(fake.thread_start_count, 2, "new thread should start after cleanup")
end

local function complete_declaration(code)
  seal._notification("item/completed", {
    threadId = "fork-thread",
    turnId = "fork-turn",
    item = { type = "agentMessage", phase = "final_answer", text = vim.json.encode({ code = code }) },
  })
  seal._notification("turn/completed", {
    threadId = "fork-thread",
    turnId = "fork-turn",
    turn = { id = "fork-turn", status = "completed" },
  })
  vim.wait(1000, function()
    return seal._state.preview ~= nil
  end)
end

function tests.preview_accepts_as_one_edit()
  setup({ "  ", "  local existing = true" })
  seal.submit("fun: load it")
  complete_declaration("function load()\n  return true\nend")
  truthy(seal._state.preview, "completed declaration should create a preview")
  truthy(seal.accept(), "accept should insert the preview")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "  function load()",
    "    return true",
    "  end",
    "  local existing = true",
  }, "accepted code should replace the blank insertion line")
  vim.cmd("undo")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "  ", "  local existing = true" }, "one undo should remove the declaration")
end

function tests.reject_leaves_buffer_untouched()
  setup({ "" })
  seal.submit("fun: stored state")
  complete_declaration("function stored_state() end")
  truthy(seal.reject(), "reject should clear the preview")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "" }, "reject must not edit the buffer")
end

function tests.stale_result_is_discarded()
  setup({ "" })
  seal.submit("fun: stale")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
  complete_declaration("function stale() end")
  truthy(seal._state.preview == nil, "changed buffer must not receive a preview")
  truthy(notifications[#notifications].message:find("changed", 1, true), "stale result should explain why it was discarded")
end

function tests.multiple_declarations_are_rejected()
  setup({ "" })
  seal.submit("fun: too many")
  seal._notification("item/completed", {
    threadId = "fork-thread",
    turnId = "fork-turn",
    item = {
      type = "agentMessage",
      phase = "final_answer",
      text = vim.json.encode({ code = "function one() end\nfunction two() end" }),
    },
  })
  seal._notification("turn/completed", {
    threadId = "fork-thread",
    turnId = "fork-turn",
    turn = { id = "fork-turn", status = "completed" },
  })
  vim.wait(1000, function()
    return seal._state.generation == nil
  end)
  truthy(seal._state.preview == nil, "multiple declarations must not be previewed")
  truthy(notifications[#notifications].message:find("expected one declaration", 1, true), "rejection should explain the syntax-unit count")
end

function tests.wrong_declaration_kind_is_rejected()
  setup({ "" })
  seal.submit("fun: not actually a function")
  seal._notification("item/completed", {
    threadId = "fork-thread",
    turnId = "fork-turn",
    item = {
      type = "agentMessage",
      phase = "final_answer",
      text = vim.json.encode({ code = "local value = 1" }),
    },
  })
  seal._notification("turn/completed", {
    threadId = "fork-thread",
    turnId = "fork-turn",
    turn = { id = "fork-turn", status = "completed" },
  })
  vim.wait(1000, function()
    return seal._state.generation == nil
  end)
  truthy(seal._state.preview == nil, "the wrong declaration kind must not be previewed")
  truthy(notifications[#notifications].message:find("expected a function", 1, true), "kind rejection should be explicit")
end

function tests.wrapper_with_multiple_functions_is_rejected()
  setup({ "" })
  local snapshot = seal._capture()
  local valid = seal._validate_declaration(snapshot, {
    "do",
    "  function one() end",
    "  function two() end",
    "end",
  }, "function")
  truthy(not valid, "a wrapper containing multiple functions must not pass as one function")
end

function tests.javascript_arrow_function_is_accepted()
  setup({ "" })
  vim.bo.filetype = "javascript"
  local snapshot = seal._capture()
  local valid, reason = seal._validate_declaration(snapshot, { "const load = () => true;" }, "function")
  truthy(valid, reason or "a JavaScript arrow function should validate as one function")
end

function tests.prompt_keeps_originating_snapshot()
  setup({ "original" })
  local deliver
  seal.setup({
    client = fake,
    save_before_agent = false,
    root = function()
      return "/tmp/seal-project"
    end,
    terminal = function(spec)
      table.insert(terminals, spec)
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    input = function(_, callback)
      deliver = callback
    end,
    keymaps = { prompt = false, terminal = false },
  })
  seal.prompt()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited while prompting" })
  deliver("explain")
  truthy(request(fake, "turn/start") == nil, "changed origin buffer should prevent submission")
end

local order = {
  "routes_only_known_prefixes",
  "normalizes_nested_indentation",
  "large_context_keeps_cursor_line",
  "visual_selection_shares_the_context_budget",
  "freeform_uses_main_thread_unchanged",
  "freeform_steers_an_active_turn",
  "declaration_waits_for_active_main_turn",
  "declaration_uses_safe_ephemeral_fork",
  "first_declaration_handles_empty_main_thread",
  "thread_setting_changes_flow_into_forks",
  "null_thread_settings_are_omitted_from_forks",
  "server_request_opens_owning_project_terminal",
  "superseded_fork_is_unsubscribed",
  "new_thread_interrupts_and_detaches_old_thread",
  "preview_accepts_as_one_edit",
  "reject_leaves_buffer_untouched",
  "stale_result_is_discarded",
  "multiple_declarations_are_rejected",
  "wrong_declaration_kind_is_rejected",
  "wrapper_with_multiple_functions_is_rejected",
  "javascript_arrow_function_is_accepted",
  "prompt_keeps_originating_snapshot",
}

for _, name in ipairs(order) do
  tests[name]()
  io.stdout:write("ok - " .. name .. "\n")
end

seal._reset()
io.stdout:write(string.format("%d tests passed\n", #order))
