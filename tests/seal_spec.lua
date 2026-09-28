local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local seal = require("seal")
local test_root = vim.fn.tempname() .. "-seal-project"
local second_root = test_root .. "-second"
local other_root = test_root .. "-other"
vim.fn.mkdir(test_root, "p")

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

local function has_parser(language)
  local ok, parser = pcall(vim.treesitter.get_parser, 0, language, { error = false })
  return ok and parser ~= nil
end

local function optional_parser(language, test_name)
  if has_parser(language) then
    return true
  end
  if vim.env.SEAL_REQUIRE_OPTIONAL_PARSERS == "1" then
    fail(string.format("%s requires the %s Tree-sitter parser", test_name, language))
  end
  io.stdout:write(string.format("skip - %s (%s parser unavailable)\n", test_name, language))
  return false
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

local function response(fake, id)
  for _, item in ipairs(fake.responses) do
    if item.id == id then
      return item
    end
  end
end

local function fake_client()
  local fake = {
    requests = {},
    responses = {},
    stopped = false,
    thread_start_count = 0,
    fork_count = 0,
    declaration_turn_count = 0,
    main_turn_count = 0,
    thread_settings = {
      model = "gpt-test",
      modelProvider = "openai",
      approvalPolicy = "untrusted",
      approvalsReviewer = "user",
      sandboxPolicy = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
      activePermissionProfile = vim.NIL,
    },
  }

  function fake:start(callback)
    callback(true)
  end

  function fake:url()
    return "ws://127.0.0.1:4567"
  end

  function fake:respond(id, result)
    table.insert(self.responses, { id = id, result = result })
    return true
  end

  function fake:respond_error(id, code, message)
    table.insert(self.responses, { id = id, error = { code = code, message = message } })
    return true
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
      local result = self.thread_resume_results and self.thread_resume_results[params.threadId]
      if type(result) == "function" then
        result(callback, params)
      elseif result then
        callback(vim.deepcopy(result))
      else
        callback(nil, { message = "missing" })
      end
    elseif method == "thread/read" then
      callback({
        thread = {
          id = params.threadId,
          cwd = test_root,
          status = self.thread_status or { type = "idle" },
          turns = params.includeTurns and (self.thread_turns or {}) or {},
        },
      })
    elseif method == "thread/fork" then
      if self.fork_error then
        callback(nil, { message = "no rollout found for thread id" })
      else
        self.fork_count = self.fork_count + 1
        local id = self.fork_count == 1 and "fork-thread" or "fork-thread-" .. self.fork_count
        callback({ thread = { id = id, status = { type = "idle" }, ephemeral = true } })
      end
    elseif method == "turn/start" then
      if params.threadId == "main-thread" then
        self.main_turn_count = self.main_turn_count + 1
        local id = self.main_turn_count == 1 and "main-turn" or "main-turn-" .. self.main_turn_count
        callback({ turn = { id = id } })
      else
        self.declaration_turn_count = self.declaration_turn_count + 1
        local id = self.declaration_turn_count == 1 and "fork-turn" or "fork-turn-" .. self.declaration_turn_count
        callback({ turn = { id = id } })
      end
    elseif method == "thread/settings/update" then
      callback({})
      self.thread_settings.approvalPolicy = params.approvalPolicy
      self.thread_settings.approvalsReviewer = params.approvalsReviewer
      if params.permissions then
        self.thread_settings.activePermissionProfile = { id = params.permissions }
      else
        self.thread_settings.activePermissionProfile = vim.NIL
        self.thread_settings.sandboxPolicy = vim.deepcopy(params.sandboxPolicy)
      end
      local updated = vim.deepcopy(self.thread_settings)
      vim.schedule(function()
        if seal._state.client == self then
          seal._notification("thread/settings/updated", {
            threadId = params.threadId,
            threadSettings = updated,
          })
        end
      end)
    else
      callback({})
    end
  end

  return fake
end

local notifications
local fake
local copied
local buffer_sequence = 0

local function setup(lines, overrides, before_setup)
  seal._reset()
  notifications = {}
  copied = nil
  fake = fake_client()
  local options = {
    client = fake,
    save_before_agent = false,
    agent_prefixes = {
      patch = {
        bounded_patch = true,
        instruction = "Make the minimum necessary change; do not run tests, builds, linters, formatters. Do not delegate this request to subagents.",
      },
    },
    root = function()
      return test_root
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    keymaps = { prompt = false, chat = false },
  }
  if before_setup then
    before_setup()
  end
  seal.setup(vim.tbl_deep_extend("force", options, overrides or {}))
  vim.cmd("enew!")
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= current and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  buffer_sequence = buffer_sequence + 1
  vim.bo.filetype = "lua"
  local buffer_path = string.format(test_root .. "/example-%d.lua", buffer_sequence)
  vim.fn.delete(buffer_path)
  vim.api.nvim_buf_set_name(0, buffer_path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines or { "" })
  local undolevels = vim.bo.undolevels
  vim.bo.undolevels = -1
  vim.bo.undolevels = undolevels
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local tests = {}
local complete_declaration

function tests.routes_only_known_prefixes()
  setup()
  equal(seal._route(" fun: load it "), {
    mode = "declaration",
    kind = "function",
    prompt = "load it",
    original = "fun: load it",
  }, "fun prefix should select declaration mode")
  equal(seal._route("TYPE: durable state").kind, "type", "prefixes should be case insensitive")
  local patch = seal._route(" PATCH: fix only the parser edge case ")
  equal(patch.mode, "agent", "patch should remain a main-thread prompt")
  equal(patch.prompt, "fix only the parser edge case", "patch should strip its control prefix")
  truthy(patch.bounded_patch, "patch should use the bounded patch lifecycle")
  truthy(patch.instruction:find("minimum necessary", 1, true), "patch should add the minimal-change policy")
  local interface = seal._route("INTERFACE: storage backend")
  equal(interface.kind, "interface", "interface should remain an inline declaration")
  truthy(
    interface.instruction:find("no concrete implementation logic", 1, true),
    "interface should prohibit implementation bodies"
  )
  equal(seal._route("fun add build logging").mode, "agent", "a declaration prefix should require a colon")
  equal(seal._route("fix: this bug").mode, "agent", "unknown colon prefixes should remain freeform")
  equal(seal._route("https://example.com").mode, "agent", "URLs should remain freeform")
  equal(seal._route("  preserve me  ").prompt, "  preserve me  ", "freeform whitespace should be preserved")

  setup(nil, { agent_prefixes = { patch = "Use custom instructions." } })
  truthy(not seal._route("patch: fix it").bounded_patch, "custom instruction strings must not imply a patch limit")
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

function tests.visual_prompt_mapping_uses_the_active_selection()
  setup({ "first", "second", "third" }, {
    input = function(_, callback)
      callback("explain this selection")
    end,
    keymaps = { prompt = "gA", chat = false },
  })
  vim.cmd("normal! ggVj")
  local mapping = vim.fn.maparg("gA", "x", false, true)
  truthy(type(mapping.callback) == "function", "the visual prompt mapping should be installed")
  mapping.callback()

  local activity = seal._state.activities[1]
  truthy(activity ~= nil, "the visual mapping should submit a prompt")
  equal(activity.snapshot.selection_range, { line1 = 1, line2 = 2 },
    "the prompt should use the selection that is active when the mapping runs")
  equal(activity.snapshot.selection, "first\nsecond", "the selected text should not come from stale visual marks")
end

function tests.repeated_setup_removes_only_its_old_global_keymaps()
  setup({ "" }, { keymaps = { prompt = "gA", chat = "gC" } })
  local replacement = function() end
  vim.keymap.set("n", "gA", replacement)
  seal.setup({
    client = fake,
    save_before_agent = false,
    root = function()
      return test_root
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    keymaps = { prompt = "gB", chat = false },
  })
  equal(vim.fn.maparg("gA", "n", false, true).callback, replacement,
    "setup must preserve a user mapping that replaced Seal's old mapping")
  truthy(vim.fn.maparg("gA", "x", false, true).callback == nil,
    "setup should remove Seal's old visual mapping")
  truthy(vim.fn.maparg("gC", "n", false, true).callback == nil,
    "setup should remove Seal's old chat mapping")
  truthy(type(vim.fn.maparg("gB", "n", false, true).callback) == "function",
    "setup should install the new prompt mapping")
  vim.keymap.del("n", "gA")
end

function tests.repeated_setup_removes_leader_keymaps_after_termcode_expansion()
  local previous_leader = vim.g.mapleader
  vim.g.mapleader = " "
  setup({ "" }, { keymaps = { prompt = "<leader>ai", chat = "<leader>ac" } })
  truthy(type(vim.fn.maparg("<leader>ai", "n", false, true).callback) == "function",
    "the fixture should install the leader prompt mapping")
  seal.setup({
    client = fake,
    save_before_agent = false,
    root = function()
      return test_root
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    keymaps = { prompt = false, chat = false },
  })
  truthy(vim.fn.maparg("<leader>ai", "n", false, true).callback == nil,
    "setup should remove the termcode-expanded normal mapping")
  truthy(vim.fn.maparg("<leader>ai", "x", false, true).callback == nil,
    "setup should remove the termcode-expanded visual mapping")
  truthy(vim.fn.maparg("<leader>ac", "n", false, true).callback == nil,
    "setup should remove the termcode-expanded chat mapping")
  vim.g.mapleader = previous_leader
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
  equal(turn.params.approvalPolicy, "untrusted", "file patches should pause for native review")
  equal(turn.params.approvalsReviewer, "user", "Seal should keep approval decisions with the user")
  equal(turn.params.sandboxPolicy, {
    type = "workspaceWrite",
    writableRoots = {},
    networkAccess = false,
  }, "normal turns should use a protocol-valid workspace-writing policy")
  equal(request(fake, "thread/start").params.approvalPolicy, "untrusted", "the main thread should review patches")
  equal(request(fake, "thread/start").params.approvalsReviewer, "user", "the main thread should not auto-review")
  equal(request(fake, "thread/start").params.sandbox, "workspace-write", "the main thread should be workspace-writing")
end

function tests.routine_turn_notifications_require_verbose_mode()
  setup({ "local value = 1" })
  seal.submit("explain this file")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  for _, notification in ipairs(notifications) do
    truthy(not notification.message:find("Prompt sent to Codex", 1, true),
      "default mode should not announce prompt dispatch")
    truthy(not notification.message:find("Codex turn finished", 1, true),
      "default mode should not announce routine completion")
  end

  setup({ "local value = 1" }, { verbose = true })
  seal.submit("explain this file")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  local sent = false
  local finished = false
  for _, notification in ipairs(notifications) do
    sent = sent or notification.message:find("Prompt sent to Codex", 1, true) ~= nil
    finished = finished or notification.message:find("Codex turn finished", 1, true) ~= nil
  end
  truthy(sent, "verbose mode should announce prompt dispatch")
  truthy(finished, "verbose mode should announce routine completion")
end

function tests.patch_adds_minimal_change_guidance_to_the_main_thread()
  setup({ "local value = 1" }, {
    main_approval_policy = "never",
    main_approvals_reviewer = "auto_review",
  })
  truthy(seal.submit("PATCH: fix only the parser edge case"), "patch prompt should submit")
  local turn = request(fake, "turn/start")
  equal(turn.params.threadId, "main-thread", "patch should use the persistent thread")
  truthy(request(fake, "thread/fork") == nil, "patch must not create a declaration fork")
  truthy(turn.params.outputSchema == nil, "patch must not constrain the agent response")
  equal(turn.params.approvalPolicy, "untrusted", "patch patches should force the review gate")
  equal(turn.params.approvalsReviewer, "user", "patch reviews should stay with the user")
  local restore = request(fake, "thread/settings/update")
  equal(restore.params.approvalPolicy, "never", "patch should restore the thread's previous approval policy")
  equal(restore.params.approvalsReviewer, "auto_review", "patch should restore the previous reviewer")
  truthy(
    turn.params.input[1].text:find("minimum necessary", 1, true),
    "Codex should receive the minimal-change policy"
  )
  truthy(
    turn.params.input[1].text:find("do not run tests, builds, linters, formatters", 1, true),
    "patch should prohibit verification commands"
  )
  truthy(
    turn.params.input[1].text:find("Propose exactly one file-change patch", 1, true),
    "patch should request one patch"
  )
  truthy(
    turn.params.input[1].text:find("Do not delegate this request to subagents", 1, true),
    "patch should keep the bounded turn on the policy-controlled root agent"
  )
  truthy(
    turn.params.input[1].text:find("\n\nRequest:\nfix only the parser edge case", 1, true),
    "the policy should remain scoped to this request"
  )
  truthy(not turn.params.input[1].text:find("PATCH:", 1, true), "the control prefix should not reach Codex")
  truthy(
    turn.params.additionalContext["seal.editor"].value:find("local value = 1", 1, true),
    "patch should retain editor context"
  )

  setup({ "" })
  truthy(not seal.submit("patch:   "), "an empty patch prompt should not submit")
  truthy(request(fake, "thread/start") == nil, "an empty patch prompt should not open a thread")
end

function tests.removed_agent_prefixes_are_plain_prompts()
  for _, text in ipairs({ "TARGETED: fix the parser", "refactor: extract the branch", "refactor this function" }) do
    setup({ "local value = 1" })
    equal(seal._route(text), { mode = "agent", prompt = text, original = text },
      "removed prefixes must use the ordinary prompt route")
    truthy(seal.submit(text), "the ordinary prompt should submit")
    local turn = request(fake, "turn/start")
    equal(turn.params.input[1].text, text, "removed prefixes must not expand instructions or strip text")
    truthy(not seal._state.live[test_root].current.bounded_patch, "ordinary prompts must allow multiple edits")
  end
end

function tests.bounded_policy_restore_accepts_app_server_workspace_defaults()
  setup({ "local value = 1" }, {
    main_approval_policy = "never",
    main_approvals_reviewer = "auto_review",
  })
  local original_request = fake.request
  local restore_callback
  function fake:request(method, params, callback)
    if method == "thread/settings/update" then
      table.insert(self.requests, { method = method, params = params })
      restore_callback = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("patch: update the value")
  local session = seal._state.live[test_root]
  local entry = session.current
  truthy(restore_callback ~= nil, "the prior thread policy should be awaiting restoration")

  local server_workspace_policy = {
    type = "workspaceWrite",
    writableRoots = {},
    networkAccess = false,
    excludeTmpdirEnvVar = false,
    excludeSlashTmp = false,
  }
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "untrusted",
      approvalsReviewer = "user",
      sandboxPolicy = server_workspace_policy,
      activePermissionProfile = vim.NIL,
    },
  })
  equal(entry.restore_settings.approvalPolicy, "never",
    "serialized workspace defaults must not make the temporary policy become the restore target")
  equal(entry.restore_settings.approvalsReviewer, "auto_review",
    "the previous reviewer should survive the temporary policy notification")

  restore_callback({})
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "never",
      approvalsReviewer = "auto_review",
      sandboxPolicy = server_workspace_policy,
      activePermissionProfile = vim.NIL,
    },
  })
  truthy(entry.settings_restored, "the semantically identical app-server sandbox should finish restoration")
end

function tests.freeform_queues_behind_an_active_turn()
  setup({ "local value = 1", "return value" }, { activity = { interval_ms = 100000 } })
  seal.submit("first prompt")
  fake.thread_status = { type = "active", activeFlags = {} }
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("follow up exactly")
  truthy(request(fake, "turn/steer") == nil, "Seal should never steer a queued prompt into another request")
  equal(fake.main_turn_count, 1, "the second prompt should wait for the active turn")
  equal(vim.tbl_count(seal._state.activities), 2, "both cursor markers should remain visible")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local function markers()
    return vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
  end
  local before = markers()
  equal(#before, 2, "running and queued freeform prompts should both render")
  equal(before[2][4].virt_lines[1][1][1], " ○ ", "a queued prompt should have a static marker")
  seal._tick_activity()
  local after = markers()
  truthy(after[1][4].virt_lines[1][1][1] ~= before[1][4].virt_lines[1][1][1], "the running prompt should animate")
  equal(after[2], before[2], "ticking should leave the queued marker unchanged")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the queued prompt should start after the first turn")
  local second = request(fake, "turn/start")
  equal(second.params.threadId, "main-thread", "the queued prompt should use the same thread")
  equal(second.params.input[1].text, "follow up exactly", "the queued prompt must remain unchanged")
  equal(vim.tbl_count(seal._state.activities), 1, "only the queued prompt marker should remain")
  equal(#markers(), 1, "completion should clear the first prompt's progress marker")
  truthy(markers()[1][4].virt_lines[1][1][1] ~= " ○ ", "the next prompt should animate when it starts")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn-2", status = "completed" },
  })
  equal(vim.tbl_count(seal._state.activities), 0, "the second completion should clear its marker")
  equal(#markers(), 0, "completion should remove all freeform progress markers")
  equal(seal._state.spinner_timer, nil, "completion should stop the idle animation timer")
end

function tests.early_completion_waits_for_start_ownership_before_pumping()
  setup({ "local value = 1" })
  local original_request = fake.request
  local first_callback
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" and not first_callback then
      table.insert(self.requests, { method = method, params = params })
      first_callback = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("first prompt")
  local first_client_id = request(fake, "turn/start").params.clientUserMessageId
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = {
      id = "actual-turn",
      status = "inProgress",
      items = { { type = "userMessage", clientId = first_client_id } },
    },
  })
  seal.submit("follow up after completion")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "actual-turn", status = "completed" },
  })
  equal(fake.main_turn_count, 0, "an unbound completion must wait for the start response")
  equal(vim.tbl_count(seal._state.activities), 2, "both markers should remain until ownership is confirmed")
  first_callback({ turn = { id = "actual-turn" } })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 1
  end, 5), "the next queued turn should start")
  equal(vim.tbl_count(seal._state.activities), 1, "the next queued marker should remain")
  local _, activity = next(seal._state.activities)
  equal(activity.turn_id, "main-turn", "the late response must not overwrite the next turn")
end

function tests.freeform_uses_the_post_format_buffer_and_selection()
  setup({ "-- before", "local   value=1", "return   value" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local group = vim.api.nvim_create_augroup("SealFormatTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    buffer = 0,
    callback = function(args)
      vim.api.nvim_buf_set_lines(args.buf, 0, 0, false, { "-- formatted header" })
      vim.api.nvim_buf_set_lines(args.buf, 2, 4, false, { "local value = 1", "return value" })
    end,
  })

  seal.submit("explain the selection", { range = 2, line1 = 2, line2 = 3 })
  local context = request(fake, "turn/start").params.additionalContext["seal.editor"].value
  truthy(
    context:find("<selection>\nlocal value = 1\nreturn value\n</selection>", 1, true),
    "Codex should receive the formatted selection at its anchored range"
  )
  truthy(not context:find("local   value=1", 1, true), "pre-format text must not leak into the refreshed selection")
  truthy(context:find("Cursor: line 3", 1, true), "cursor context should follow lines inserted by the formatter")
  equal(vim.bo.modified, false, "the formatted buffer should be saved before the agent starts")

  vim.api.nvim_del_augroup_by_id(group)
  vim.fn.delete(path)
end

function tests.freeform_maps_context_through_a_full_buffer_format()
  setup({ "local   first=1", "local   value=2", "return   value" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local group = vim.api.nvim_create_augroup("SealFullFormatTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    buffer = 0,
    callback = function(args)
      vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, {
        "-- formatted header",
        "local first = 1",
        "local value = 2",
        "return value",
      })
    end,
  })

  seal.submit("explain the selection", { range = 2, line1 = 2, line2 = 3 })
  local context = request(fake, "turn/start").params.additionalContext["seal.editor"].value
  truthy(
    context:find("<selection>\nlocal value = 2\nreturn value\n</selection>", 1, true),
    "a full-buffer formatter should preserve the selected declaration"
  )
  truthy(context:find("Cursor: line 3", 1, true), "cursor context should follow the full-buffer replacement")

  vim.api.nvim_del_augroup_by_id(group)
  vim.fn.delete(path)
end

function tests.freeform_keeps_a_selection_expanded_by_formatting()
  setup({ "local compact=true", "return compact" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  local group = vim.api.nvim_create_augroup("SealExpandedFormatTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    buffer = 0,
    callback = function(args)
      vim.api.nvim_buf_set_lines(args.buf, 0, 1, false, {
        "local compact = {",
        "  enabled = true,",
        "}",
      })
    end,
  })

  seal.submit("explain the selection", { range = 2, line1 = 1, line2 = 1 })
  local context = request(fake, "turn/start").params.additionalContext["seal.editor"].value
  truthy(
    context:find("<selection>\nlocal compact = {\n  enabled = true,\n}\n</selection>", 1, true),
    "the selected range should include every line produced by the formatter"
  )
  truthy(
    not context:find("<selection>.-return compact.-</selection>"),
    "formatter expansion must not absorb the following line"
  )

  vim.api.nvim_del_augroup_by_id(group)
  vim.fn.delete(path)
end

function tests.preflight_reloads_an_external_edit_before_capture()
  setup({ "local old_value = true" })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.bo.autoread = true
  vim.cmd("silent write")
  vim.fn.writefile({ "local external_value = true" }, path)

  seal.submit("fun: use the current value")
  local context = request(fake, "turn/start").params.additionalContext["seal.editor"].value
  truthy(context:find("local external_value = true", 1, true), "capture should use the current file from disk")
  truthy(not context:find("local old_value = true", 1, true), "stale buffer text must not be sent to Codex")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local external_value = true" }, "the buffer should reload")
  vim.fn.delete(path)
end

function tests.preflight_preserves_local_changes_on_external_conflict()
  setup({ "local saved_value = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local unsaved_value = true" })
  vim.fn.writefile({ "local external_value = true" }, path)

  truthy(not seal.submit("change the project"), "an unresolved disk conflict should block submission")
  truthy(not seal.submit("try the project again"), "the disk conflict should remain blocked on later submissions")
  truthy(request(fake, "thread/start") == nil, "Seal should not open a thread for conflicted context")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local unsaved_value = true" }, "local changes must survive")
  equal(vim.fn.readfile(path), { "local external_value = true" }, "Seal must not overwrite the external version")
  truthy(notifications[#notifications].message:find("file conflict", 1, true), "the conflict should be explained")
  vim.fn.delete(path)
end

function tests.command_does_not_retry_a_failed_preflight()
  setup({ "local saved_value = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local unsaved_value = true" })
  vim.fn.writefile({ "local external_value = true" }, path)

  vim.cmd("Seal change the project")
  truthy(request(fake, "thread/start") == nil, ":Seal must stop after its initial context capture fails")
  equal(vim.fn.readfile(path), { "local external_value = true" }, "the command must preserve the external version")
  vim.fn.delete(path)
end

function tests.preflight_blocks_an_externally_deleted_file()
  setup({ "local saved_value = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  vim.fn.delete(path)

  truthy(not seal.submit("change the project"), "a deleted source file should block submission")
  truthy(request(fake, "thread/start") == nil, "Codex must not start with stale content from a deleted file")
  equal((vim.uv or vim.loop).fs_stat(path), nil, "Seal must not recreate the deleted file")
end

function tests.preflight_blocks_deleted_file_with_local_changes()
  setup({ "local saved_value = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local unsaved_value = true" })
  vim.fn.delete(path)

  truthy(not seal.submit("change the project"), "local changes must not silently recreate a deleted file")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local unsaved_value = true" }, "local edits must survive")
  equal((vim.uv or vim.loop).fs_stat(path), nil, "the deleted path must remain absent")
end

function tests.preflight_compares_disk_using_the_buffer_encoding()
  setup({ "" })
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ string.char(0xe9) }, path, "b")
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("edit! ++enc=latin1")

  truthy(seal.submit("explain this file"), "a non-UTF-8 file that matches its buffer should submit")
  truthy(
    request(fake, "turn/start") ~= nil,
    "encoding conversion should not look like an external edit: " .. vim.inspect(notifications)
  )
  vim.fn.delete(path)
end

function tests.preflight_compares_utf16_disk_content()
  setup({ "alpha", "é" })
  local path = vim.fn.tempname() .. ".txt"
  vim.api.nvim_buf_set_name(0, path)
  vim.bo.fileencoding = "utf-16le"
  vim.bo.bomb = true
  vim.cmd("silent write")

  truthy(seal.submit("explain this file"), "a UTF-16 file that matches its buffer should submit")
  truthy(request(fake, "turn/start") ~= nil, "UTF-16 decoding should not look like an external edit")
  vim.fn.delete(path)
end

function tests.post_write_buffer_mutation_blocks_freeform_turn()
  setup({ "local before = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  local group = vim.api.nvim_create_augroup("SealPostWriteTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = 0,
    callback = function(args)
      vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { "local after = true" })
      vim.api.nvim_set_option_value("modified", false, { buf = args.buf })
    end,
  })

  seal.submit("change the project")
  truthy(request(fake, "turn/start") == nil, "Codex must not start with post-write text that is absent from disk")
  truthy(notifications[#notifications].message:find("different from disk", 1, true), "the post-write mismatch should be explained")

  vim.api.nvim_del_augroup_by_id(group)
  vim.fn.delete(path)
end

function tests.post_write_other_buffer_mutation_blocks_freeform_turn()
  setup({ "local current = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(other, test_root .. "/post-write-other.lua")
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "local saved = true" })
  vim.api.nvim_set_option_value("modified", false, { buf = other })
  local group = vim.api.nvim_create_augroup("SealPostWriteOtherTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = 0,
    callback = function()
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "local changed = true" })
    end,
  })

  seal.submit("change the project")
  truthy(request(fake, "turn/start") == nil, "Codex must not start after a save hook dirties another project buffer")
  truthy(notifications[#notifications].message:find("other modified project buffers", 1, true), "the dirty buffer should be named")

  vim.api.nvim_del_augroup_by_id(group)
  vim.api.nvim_buf_delete(other, { force = true })
  vim.fn.delete(path)
end

function tests.post_write_buffer_wipe_aborts_without_an_error()
  setup({ "local before = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  local group = vim.api.nvim_create_augroup("SealPostWriteWipeTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = 0,
    callback = function(args)
      vim.api.nvim_buf_delete(args.buf, { force = true })
    end,
  })

  local ok, submit_error = pcall(seal.submit, "change the project")
  truthy(ok, "a save hook that closes the buffer must not crash Seal: " .. tostring(submit_error))
  truthy(request(fake, "turn/start") == nil, "Codex must not start after the source buffer closes")

  vim.api.nvim_del_augroup_by_id(group)
  vim.fn.delete(path)
end

function tests.disk_only_formatter_blocks_without_dropping_a_declaration()
  local rewrite_disk = false
  local formatter_group
  setup({ "local buffered = true" }, { activity = { interval_ms = 100000 } }, function()
    formatter_group = vim.api.nvim_create_augroup("SealDiskOnlyFormatterTest", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = formatter_group,
      callback = function(args)
        if rewrite_disk then
          vim.fn.writefile({ "local formatted_on_disk = true" }, vim.api.nvim_buf_get_name(args.buf))
        end
      end,
    })
  end)
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  seal.submit("fun: remains safe across formatting")
  truthy(seal._state.jobs[1] ~= nil, "the declaration should be running before the write")

  rewrite_disk = true
  vim.cmd("silent write")

  truthy(seal._state.jobs[1] ~= nil, "a disk-only formatter should retain the proposal until the buffer reloads")
  equal(
    vim.api.nvim_buf_get_lines(0, 0, -1, false),
    { "local buffered = true" },
    "the safety check should not silently replace the editor buffer"
  )
  vim.api.nvim_del_augroup_by_id(formatter_group)
  vim.fn.delete(path)
end

function tests.completed_attached_tui_turn_reloads_external_edits()
  setup({ "local original = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.bo.autoread = true
  vim.cmd("silent write")

  seal.submit("change this file")
  vim.fn.writefile({ "local changed_by_codex = true" }, path)
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "tui-turn", status = "completed" },
  })
  local reloaded = vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "local changed_by_codex = true"
  end)
  truthy(reloaded, "an unmodified buffer should reload changes made by the background Codex turn")
  vim.fn.delete(path)
end

function tests.completed_turn_does_not_check_unrelated_projects()
  setup({ "local current = true" }, {
    root = function(buf)
      local path = vim.api.nvim_buf_get_name(buf)
      return path:find("seal%-other%-project") and other_root or test_root
    end,
  })
  seal.submit("change this project")

  local other_path = vim.fn.tempname():gsub("/[^/]+$", "/seal-other-project.lua")
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(other, other_path)
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "local original = true" })
  vim.api.nvim_set_option_value("autoread", true, { buf = other })
  vim.api.nvim_buf_call(other, function()
    vim.cmd("silent write")
  end)
  vim.fn.writefile({ "local external = true" }, other_path)

  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "tui-turn", status = "completed" },
  })
  vim.wait(100, function()
    return false
  end)
  equal(
    vim.api.nvim_buf_get_lines(other, 0, -1, false),
    { "local original = true" },
    "a Seal turn must not reload buffers from another project"
  )

  vim.api.nvim_buf_delete(other, { force = true })
  vim.fn.delete(other_path)
end

function tests.completed_turn_preserves_a_modified_external_conflict()
  setup({ "local saved = true" }, { save_before_agent = true })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  seal.submit("first turn")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local unsaved = true" })
  vim.fn.writefile({ "local external = true" }, path)

  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  vim.wait(100, function()
    return false
  end)
  truthy(not seal.submit("second turn"), "a later prompt must stop at the local/external conflict")
  truthy(request(fake, "turn/start", 2) == nil, "the conflicted second turn must not start")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local unsaved = true" }, "the local version must survive")
  equal(vim.fn.readfile(path), { "local external = true" }, "the external version must survive")
  vim.fn.delete(path)
end

function tests.freeform_refuses_other_modified_project_buffers()
  setup({ "local current = true" })
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(other, test_root .. "/other-unsaved.lua")
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "local unsaved = true" })

  seal.submit("change the project")
  truthy(request(fake, "turn/start") == nil, "Codex should not start while another project buffer is unsaved")
  truthy(notifications[#notifications].message:find("other modified project buffers", 1, true), "the conflict should be explained")
  vim.api.nvim_buf_delete(other, { force = true })
end

function tests.chat_reads_and_renders_the_backing_thread()
  setup({ "local value = 1" })
  seal.submit("explain the value")
  fake.thread_turns = {
    {
      id = "turn-1",
      status = "completed",
      items = {
        { id = "user-1", type = "userMessage", content = { { type = "text", text = "explain the value" } } },
        { id = "tool-1", type = "commandExecution", command = "secret noisy command", status = "completed" },
        { id = "agent-1", type = "agentMessage", phase = "final_answer", text = "It is the cached value." },
      },
    },
  }

  local source = vim.api.nvim_get_current_buf()
  seal.chat()
  local read = request(fake, "thread/read")
  equal(read.params.includeTurns, true, "chat should request persisted turns and items")
  truthy(vim.api.nvim_get_current_buf() ~= source, "chat should open a scratch buffer")
  equal(vim.bo.buftype, "nofile", "chat should not be backed by a file")
  equal(vim.bo.modifiable, false, "chat should be read-only")
  equal(vim.bo.readonly, true, "chat should reject file-style edits")
  local rendered = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  truthy(rendered:find("## You\n\nexplain the value", 1, true), "chat should render the user message")
  truthy(rendered:find("## Codex\n\nIt is the cached value.", 1, true), "chat should render the Codex answer")
  truthy(not rendered:find("secret noisy command", 1, true), "chat should omit tool activity")
  fake.thread_turns[1].items[3].text = "It is the refreshed cached value."
  vim.fn.maparg("r", "n", false, true).callback()
  rendered = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  truthy(rendered:find("It is the refreshed cached value.", 1, true),
    "the chat refresh mapping should re-read and render the backing thread")
  seal.submit("follow up from chat")
  equal(fake.main_turn_count, 1, "a chat follow-up should queue behind the active turn")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the chat follow-up should start after the active turn")
  local follow_up = request(fake, "turn/start", 2)
  equal(follow_up.params.threadId, "main-thread", "prompting from chat should reuse its backing thread")
  truthy(follow_up.params.additionalContext["seal.editor"].value:find("example-", 1, true), "chat prompts should retain the source buffer context")
  vim.fn.maparg("q", "n", false, true).callback()
  equal(vim.api.nvim_get_current_buf(), source, "closing chat should return to the source buffer")
end

function tests.attach_before_a_prompt_lets_the_side_tui_create_the_shared_thread()
  setup({ "" }, {
    attach_timeout_ms = 100000,
    copy = function(value)
      copied = value
    end,
  })
  local resume_callback
  fake.thread_resume_results = {
    ["side-pane-thread"] = function(callback)
      resume_callback = callback
    end,
  }
  seal.attach()
  truthy(copied:find("codex", 1, true), "attach command should invoke Codex")
  truthy(not copied:find("resume", 1, true),
    "an empty chat should let the TUI create a materialized thread instead of resuming an empty rollout")
  truthy(copied:find("--remote", 1, true), "attach command should use the app-server transport")
  truthy(copied:find("ws://127.0.0.1:4567", 1, true), "attach command should use Seal's live endpoint")
  truthy(copied:find(test_root, 1, true), "the new TUI chat should start in the Seal project")
  truthy(request(fake, "thread/start") == nil,
    ":SealAttach should not create an unresumable empty app-server thread")
  truthy(seal.status().attaching, "Seal should wait to adopt the side-pane thread")

  seal.submit("patch: update the visible chat")
  truthy(request(fake, "turn/start") == nil,
    "a prompt entered during handoff should wait for the TUI-created thread")
  seal._notification("thread/started", {
    thread = {
      id = "unrelated-thread",
      cwd = second_root,
      status = { type = "idle" },
      modelProvider = "openai",
      parentThreadId = vim.NIL,
    },
  })
  truthy(seal.status().attaching, "an unrelated thread must not steal the pending handoff")
  seal._notification("thread/started", {
    thread = {
      id = "side-pane-thread",
      cwd = test_root,
      status = { type = "idle" },
      modelProvider = "openai",
      parentThreadId = vim.NIL,
    },
  })
  local resume = request(fake, "thread/resume")
  equal(resume.params, {
    threadId = "side-pane-thread",
    excludeTurns = true,
  }, "Seal should subscribe its own app-server connection before adopting the TUI thread")
  truthy(resume_callback ~= nil, "the adoption handoff should wait for the subscription response")
  truthy(request(fake, "turn/start") == nil,
    "a waiting prompt must not start before Seal is subscribed to its lifecycle events")
  truthy(seal.status().attaching, "the handoff should remain pending while Seal subscribes")

  resume_callback({
    thread = {
      id = "side-pane-thread",
      cwd = test_root,
      status = { type = "idle" },
      turns = {},
    },
    model = "gpt-test",
    modelProvider = "openai",
    approvalPolicy = "untrusted",
    approvalsReviewer = "user",
    sandbox = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
  })
  local turn = request(fake, "turn/start")
  equal(turn.params.threadId, "side-pane-thread",
    "the waiting patch prompt should run in the chat created by the side TUI")
  truthy(turn.params.input[1].text:find("update the visible chat", 1, true) ~= nil,
    "the side-pane turn should receive the original prompt")
  equal(seal.status().thread_id, "side-pane-thread", "Seal should retain the adopted TUI chat")
  truthy(not seal.status().attaching, "the handoff should finish after thread/started")
end

function tests.attach_resumes_a_thread_after_its_first_turn_materializes()
  setup({ "" }, {
    copy = function(value)
      copied = value
    end,
  })
  seal.submit("materialize the shared chat")
  seal.attach()
  truthy(copied:find("resume", 1, true), "a materialized thread should use exact resume")
  truthy(copied:find("--remote", 1, true), "resume should use the app-server transport")
  truthy(copied:find("ws://127.0.0.1:4567", 1, true), "resume should use Seal's live endpoint")
  truthy(copied:find("main-thread", 1, true), "attach command should target the backing chat thread")
end

function tests.attach_keeps_the_empty_fallback_subscribed_until_adoption()
  setup({ "" }, {
    attach_timeout_ms = 100000,
    copy = function(value)
      copied = value
    end,
  })
  seal.chat()
  equal(seal.status().thread_id, "main-thread", "chat should create the empty fallback thread")

  fake.thread_resume_results = {
    ["side-pane-thread"] = {
      thread = {
        id = "side-pane-thread",
        cwd = test_root,
        status = { type = "idle" },
        turns = {},
      },
      model = "gpt-test",
      modelProvider = "openai",
      approvalPolicy = "untrusted",
      approvalsReviewer = "user",
      sandbox = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
    },
  }

  seal.attach()
  truthy(seal.status().attaching, "attach should replace an unmaterialized fallback")
  truthy(request(fake, "thread/unsubscribe") == nil,
    "the fallback must remain subscribed while it can still be restored")

  seal._notification("thread/started", {
    thread = {
      id = "side-pane-thread",
      cwd = test_root,
      status = { type = "idle" },
      modelProvider = "openai",
      parentThreadId = vim.NIL,
    },
  })
  equal(request(fake, "thread/unsubscribe").params.threadId, "main-thread",
    "the obsolete fallback should detach after the side-pane thread is adopted")
end

function tests.wiped_chat_ignores_a_delayed_refresh()
  setup({ "" })
  seal.submit("start the chat")
  seal.chat()
  local source = seal._state.chat.return_buf
  local original_request = fake.request
  local held_read
  function fake:request(method, params, callback)
    if method == "thread/read" and params.includeTurns then
      table.insert(self.requests, { method = method, params = params })
      held_read = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.chat()
  truthy(held_read ~= nil, "refresh should be held for the race test")
  vim.api.nvim_set_current_buf(source)
  held_read({
    thread = {
      id = "main-thread",
      cwd = test_root,
      status = { type = "idle" },
      turns = {},
    },
  })
  truthy(seal._state.chat == nil, "a delayed refresh must not reopen a wiped chat")
  equal(vim.api.nvim_get_current_buf(), source, "a delayed refresh must not steal focus")
end

function tests.declaration_queues_during_active_main_turn()
  setup({ "" })
  seal.submit("patch: make the surrounding change")
  fake.thread_status = { type = "active", activeFlags = {} }
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  seal.submit("fun: run alongside the patch turn")
  truthy(request(fake, "thread/fork") == nil, "a declaration should not fork the backing chat")
  equal(fake.main_turn_count, 1, "the declaration should wait for the patch turn")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the declaration should start after the patch turn")
  equal(request(fake, "turn/start").params.threadId, "main-thread", "the declaration should reuse the backing chat")
  complete_declaration("function run_after_patch() end")
  seal.reject(1)
end

function tests.declaration_uses_shared_read_only_turn()
  setup({ "  " })
  truthy(seal.submit("fun: load the durable state"), "declaration prompt should submit")
  truthy(request(fake, "thread/fork") == nil, "declarations should not fork the persistent chat")

  local turn = request(fake, "turn/start")
  equal(turn.params.threadId, "main-thread", "declaration should run in the persistent chat")
  equal(turn.params.sandboxPolicy, { type = "readOnly", networkAccess = false }, "declaration should be read-only")
  equal(turn.params.approvalPolicy, "never", "declaration should not wait for tool approvals")
  truthy(turn.params.input[1].text:find("exactly one function", 1, true), "turn should carry the declaration contract")
  truthy(turn.params.input[1].text:find("load the durable state", 1, true), "turn should carry the user's intent")
  equal(turn.params.outputSchema.required, { "code" }, "declaration should require structured code")
  local restored = request(fake, "thread/settings/update")
  equal(restored.params.sandboxPolicy.type, "workspaceWrite", "declaration should restore the shared thread sandbox")
  equal(restored.params.approvalPolicy, "untrusted", "declaration should restore the review policy")
end

function tests.interface_prefix_requests_api_without_implementation()
  setup({ "" })
  truthy(seal.submit("INTERFACE: storage backend"), "interface prompt should submit")
  local turn = request(fake, "turn/start")
  equal(turn.params.threadId, "main-thread", "interface should run in the persistent chat")
  truthy(turn.params.input[1].text:find("exactly one interface", 1, true), "interface should keep the declaration contract")
  truthy(
    turn.params.input[1].text:find("no concrete implementation logic", 1, true),
    "interface should request signatures without implementations"
  )
  truthy(turn.params.input[1].text:find("storage backend", 1, true), "interface should carry the user's request")
  truthy(
    not turn.params.input[1].text:find("minimum necessary", 1, true),
    "interface should not inherit the patch policy"
  )
  equal(turn.params.outputSchema.required, { "code" }, "interface should retain structured declaration output")
end

function tests.first_declaration_starts_the_shared_thread()
  setup({ "" })
  seal.submit("type: cached value")
  local starts = {}
  for _, item in ipairs(fake.requests) do
    if item.method == "thread/start" then
      table.insert(starts, item)
    end
  end
  equal(#starts, 1, "a declaration should create only the persistent project thread")
  equal(request(fake, "turn/start").params.threadId, "main-thread", "declaration should run on that thread")
end

function tests.thread_setting_changes_stay_on_the_shared_thread()
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
      approvalPolicy = "on-request",
      approvalsReviewer = "auto_review",
      sandboxPolicy = { type = "dangerFullAccess" },
      activePermissionProfile = vim.NIL,
    },
  })
  seal.submit("fun: inherit settings")
  equal(fake.main_turn_count, 1, "the declaration should queue behind the establishing turn")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the declaration should start on the updated shared thread")
  local turn = request(fake, "turn/start")
  equal(turn.params.threadId, "main-thread", "updated thread settings should be inherited without a fork")
  truthy(turn.params.model == nil, "the turn should inherit the thread's current model")
  local restored = request(fake, "thread/settings/update")
  equal(restored.params.approvalPolicy, "on-request", "the declaration should preserve the TUI approval policy")
  equal(restored.params.approvalsReviewer, "auto_review", "the declaration should preserve the TUI reviewer")
  equal(restored.params.sandboxPolicy, { type = "dangerFullAccess" }, "the declaration should preserve the TUI sandbox")
end

function tests.declaration_restores_main_thread_settings()
  setup({ "" })
  seal.submit("establish the shared thread")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "never",
      approvalsReviewer = "guardian_subagent",
      sandboxPolicy = { type = "dangerFullAccess" },
      activePermissionProfile = { id = "yolo", extends = vim.NIL },
    },
  })
  seal.submit("fun: restore settings")
  local restored = request(fake, "thread/settings/update")
  equal(restored.params.threadId, "main-thread", "settings should be restored on the shared thread")
  equal(restored.params.approvalPolicy, "never", "the active TUI approval policy should survive")
  equal(restored.params.approvalsReviewer, "guardian_subagent", "the active TUI reviewer should survive")
  equal(restored.params.permissions, "yolo", "the active TUI permission profile should survive")
  truthy(restored.params.sandboxPolicy == nil, "a named permission profile must not be combined with a sandbox")
end

function tests.declaration_turn_declines_file_changes()
  setup({ "" })
  seal.submit("fun: remain read-only")
  seal._server_request({
    id = 40,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "unexpected-patch" },
  })
  equal(fake.responses[#fake.responses], {
    id = 40,
    result = { decision = "decline" },
  }, "a declaration turn must not open a writable patch review")
  truthy(seal._state.reviews["40"] == nil, "the read-only declaration should not create a review")
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { type = "collabAgentToolCall", receiverThreadIds = { "declaration-child" } },
  })
  seal._server_request({
    id = 41,
    method = "item/fileChange/requestApproval",
    params = { threadId = "declaration-child", turnId = "declaration-child-turn", itemId = "child-patch" },
  })
  equal(fake.responses[#fake.responses], {
    id = 41,
    result = { decision = "decline" },
  }, "a declaration subagent must remain read-only")
  seal.reject(1)
end

function tests.declaration_retries_after_a_tui_turn_wins_the_start_race()
  setup({ "" })
  local original_request = fake.request
  local held_start
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" and not held_start then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: wait for the TUI")
  local job = seal._state.jobs[1]
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = {
      id = "tui-race-turn",
      status = "inProgress",
      items = { { type = "userMessage", clientId = "tui-client" } },
    },
  })
  equal(job.turn_id, nil, "an unrelated TUI notification must not claim the declaration")
  truthy(seal._state.owned_turns["tui-race-turn"] == nil, "Seal must not claim the TUI turn")

  held_start(nil, { message = "thread already has an active turn" })
  equal(job.thread_id, nil, "the declaration should return to the queue")
  truthy(request(fake, "turn/interrupt") == nil, "the TUI turn must not be interrupted")
  truthy(request(fake, "thread/settings/update") == nil,
    "a rejected start with unchanged settings must not wait for a no-op update event")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "tui-race-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return job.turn_id == "main-turn"
  end, 5), "the declaration should retry after the TUI turn")
  complete_declaration("function after_tui() end")
  local session = seal._state.live[test_root]
  truthy(session.scheduler:current_lease() == nil, "the retried declaration must restore and release its second lease")
  seal.submit("follow the retried declaration")
  equal(fake.main_turn_count, 2, "a later prompt should start after the retried restore barrier")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn-2", status = "completed" },
  })
  seal.reject(1)
end

function tests.stale_status_read_does_not_block_the_queue()
  setup({ "" })
  local original_request = fake.request
  local held_read
  function fake:request(method, params, callback)
    if method == "thread/read" and not held_read then
      table.insert(self.requests, { method = method, params = params })
      held_read = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: survive stale status")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "short-tui-turn", status = "inProgress", items = {} },
  })
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "short-tui-turn", status = "completed" },
  })
  held_read({
    thread = {
      id = "main-thread",
      status = { type = "active", activeFlags = {} },
    },
  })
  equal(fake.main_turn_count, 1, "the stale active response must not block the declaration")
  seal.reject(1)
end

function tests.failed_settings_restore_blocks_the_next_turn()
  setup({ "", "" })
  local original_request = fake.request
  function fake:request(method, params, callback)
    if method == "thread/settings/update" then
      table.insert(self.requests, { method = method, params = params })
      callback(nil, { message = "settings restore failed" })
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: first")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: second")
  complete_declaration("function first() end")
  equal(fake.main_turn_count, 1, "the second turn must not start with declaration permissions")
  truthy(seal._state.live[test_root].settings_blocked, "the unsafe thread should remain blocked")
  equal(seal._state.jobs[1].phase, "ready", "the completed declaration should still reach preview")
  equal(seal._state.jobs[2].phase, "generating", "the queued declaration should remain pending")
end

function tests.rejected_declaration_start_does_not_wait_for_a_noop_restore()
  setup({ "" })
  local original_request = fake.request
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      callback(nil, { message = "turn rejected before dispatch" })
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: reject before applying settings")
  truthy(request(fake, "thread/settings/update") == nil,
    "a rejected start must not enqueue an A-to-A restore and wait for a notification")
  local session = seal._state.live[test_root]
  truthy(session.scheduler:current_lease() == nil, "the failed start should release its restore lease")
  truthy(vim.tbl_isempty(seal._state.jobs), "the rejected declaration should leave no stale marker")
end

function tests.stale_restore_marker_cannot_drop_a_new_lease_obligation()
  setup({ "" })
  local original_request = fake.request
  local held_start
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: release a retried restore lease")
  local session = seal._state.live[test_root]
  local entry = session.current
  entry.settings_restore_started = true
  entry.settings_restore_token = "superseded-lease"
  entry.settings_restored = true
  held_start(nil, { message = "turn rejected before dispatch" })

  truthy(vim.wait(500, function()
    return session.scheduler:current_lease() == nil
  end, 5), "a stale entry marker must not leave the current lease finalizing forever")
  truthy(vim.tbl_isempty(seal._state.jobs), "the failed declaration should still be removed")
end

function tests.server_request_is_resolved_without_an_interactive_client()
  setup({ "" }, {
    auto_approve_commands = true,
    select = function()
      fail("automatic command approval should not require an interactive client")
    end,
  })
  seal._state.live["/tmp/project-a"] = { root = "/tmp/project-a", thread_id = "thread-a" }
  seal._state.owned_turns["seal-turn"] = true
  seal._server_request({
    id = 41,
    method = "item/commandExecution/requestApproval",
    params = { threadId = "thread-a", turnId = "seal-turn", command = "make test" },
  })
  equal(fake.responses[#fake.responses], {
    id = 41,
    result = { decision = "accept" },
  }, "command approval should be accepted instead of hanging")

  seal._server_request({
    id = 42,
    method = "item/permissions/requestApproval",
    params = { threadId = "thread-a", turnId = "seal-turn" },
  })
  equal(fake.responses[#fake.responses], {
    id = 42,
    result = { permissions = {}, scope = "turn" },
  }, "permission requests should receive a protocol-valid empty grant")

  seal._server_request({
    id = 43,
    method = "item/tool/requestUserInput",
    params = { threadId = "thread-a", turnId = "seal-turn" },
  })
  equal(fake.responses[#fake.responses], {
    id = 43,
    result = { answers = {} },
  }, "user-input requests should receive a protocol-valid empty response")

  seal._server_request({
    id = 44,
    method = "mcpServer/elicitation/request",
    params = { threadId = "thread-a", turnId = "seal-turn" },
  })
  equal(fake.responses[#fake.responses], {
    id = 44,
    result = { action = "decline" },
  }, "MCP elicitation should receive a protocol-valid decline")

  local response_count = #fake.responses
  seal._server_request({
    id = 45,
    method = "item/commandExecution/requestApproval",
    params = { threadId = "thread-a", turnId = "tui-turn" },
  })
  equal(#fake.responses, response_count, "Seal must let the attached TUI answer requests for its own turns")
end

function tests.multi_file_patch_waits_for_review_and_acceptance()
  setup({ "local value = 1" })
  vim.api.nvim_set_option_value("modified", false, { buf = 0 })
  seal.submit("change the storage implementation")
  local source_path = vim.api.nvim_buf_get_name(0)
  local changes = {
    {
      path = source_path,
      kind = { type = "update" },
      diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
    },
    {
      path = test_root .. "/storage.lua",
      kind = { type = "add" },
      diff = "@@ -0,0 +1 @@\n+return {}",
    },
  }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "patch-1", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 51,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "patch-1", grantRoot = vim.NIL },
  })

  local review = seal._state.reviews["51"]
  truthy(review ~= nil, "the file-change request should remain pending")
  truthy(vim.api.nvim_win_is_valid(review.view.win), "the proposed patch should open automatically")
  local rendered = table.concat(vim.api.nvim_buf_get_lines(review.view.buf, 0, -1, false), "\n")
  truthy(rendered:find("example", 1, true), "the review should show the current file")
  truthy(rendered:find("storage.lua", 1, true), "the review should show every changed file")
  equal(#fake.responses, 0, "Codex must stay paused until the user decides")

  vim.fn.maparg("q", "n", false, true).callback()
  truthy(seal._state.reviews["51"] ~= nil, "closing the view should defer rather than approve the patch")
  truthy(seal.review(test_root), ":SealReview should reopen the pending patch")
  review = seal._state.reviews["51"]
  equal(vim.api.nvim_get_current_buf(), review.view.buf, "the reopened review should be current")
  truthy(review.warning == nil, "the unchanged review should remain acceptable: " .. tostring(review.warning))
  local accept = vim.fn.maparg("<Tab>", "n", false, true)
  truthy(type(accept.callback) == "function", "the reopened review should restore its accept mapping")
  accept.callback()
  truthy(
    #fake.responses > 0,
    "acceptance should answer the app-server request: " .. vim.inspect(notifications[#notifications])
  )
  equal(fake.responses[#fake.responses], {
    id = 51,
    result = { decision = "accept" },
  }, "Tab should approve the complete multi-file patch")
  truthy(seal._state.reviews["51"] == nil, "an accepted patch should leave the review queue")
  equal(vim.tbl_count(seal._state.activities), 1, "patch acceptance should keep the turn marker visible")
  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "patch-1", type = "fileChange", status = "completed", changes = changes },
  })
  truthy(request(fake, "turn/interrupt") == nil, "a freeform patch should not stop its agentic turn")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  equal(vim.tbl_count(seal._state.activities), 0, "the marker should clear only when the turn finishes")
end

function tests.accepted_patch_reloads_its_open_buffer_when_the_item_completes()
  setup({ "local value = 1" })
  vim.wait(20)
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  seal.submit("update the value")
  local source_path = vim.api.nvim_buf_get_name(0)
  local changes = {
    {
      path = source_path,
      kind = { type = "update" },
      diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
    },
  }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "patch-reload", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 164,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "patch-reload" },
  })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  vim.fn.writefile({ "local value = 2" }, source_path)
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local value = 1" },
    "the fixture must remain stale until this patch's completion callback runs")
  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "patch-reload", type = "fileChange", status = "completed", changes = changes },
  })

  truthy(vim.wait(500, function()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "local value = 2"
  end, 5), "an applied patch should reload its unmodified open buffer before the turn finishes")
  equal(vim.tbl_count(seal._state.activities), 1, "reloading the patch should not finish the owning turn")
end

function tests.client_exit_rechecks_buffers_for_accepted_patches_without_completion_events()
  setup({ "local value = 1" })
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  local source_path = vim.api.nvim_buf_get_name(0)
  seal.submit("update the value")
  local changes = { {
    path = source_path,
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "disconnect-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 174,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "disconnect-patch" },
  })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  vim.fn.writefile({ "local value = 2" }, source_path)
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local value = 1" },
    "the fixture should still be waiting for app-server completion")

  seal._client_exit(false)
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local value = 2" },
    "disconnect cleanup should recover a patch applied before the missing completion event")
  equal(vim.tbl_count(seal._state.accepted_file_items), 0,
    "disconnect cleanup should discard accepted request bookkeeping")
end

function tests.accepted_delete_does_not_latch_a_conflict_on_its_unmodified_source_buffer()
  setup({ "local obsolete = true" })
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  local source = vim.api.nvim_get_current_buf()
  local source_path = vim.api.nvim_buf_get_name(source)
  seal.submit("delete the obsolete file")
  local changes = { {
    path = source_path,
    kind = { type = "delete" },
    diff = "@@ -1 +0,0 @@\n-local obsolete = true",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "delete-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 171,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "delete-patch" },
  })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  vim.fn.delete(source_path)
  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "delete-patch", type = "fileChange", status = "completed", changes = changes },
  })
  vim.wait(20)
  equal(seal._state.file_conflicts[source], nil,
    "an approved deletion should not be recorded as an unexpected disk conflict")
end

function tests.failed_patch_application_is_reported_and_cleared()
  setup({ "local value = 1" })
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  seal.submit("update the value")
  local changes = { {
    path = vim.api.nvim_buf_get_name(0),
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "failed-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 166,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "failed-patch" },
  })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "failed-patch", type = "fileChange", status = "failed", changes = changes },
  })
  local reported = false
  for _, notification in ipairs(notifications) do
    if notification.message:find("could not apply", 1, true) then
      reported = true
    end
  end
  truthy(reported, "a failed accepted patch should surface an error: " .. vim.inspect(notifications))
  equal(vim.tbl_count(seal._state.accepted_file_items), 0,
    "a terminal failed patch must leave no stale accepted-item state")
end

function tests.failed_bounded_patch_application_stops_and_fails_the_turn()
  setup({ "local value = 1" })
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  seal.submit("patch: update the value")
  local activity = seal._state.activities[1]
  local changes = { {
    path = vim.api.nvim_buf_get_name(0),
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "failed-bounded-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 172,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "failed-bounded-patch" },
  })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "failed-bounded-patch", type = "fileChange", status = "failed", changes = changes },
  })
  equal(request(fake, "turn/interrupt").params.turnId, "main-turn",
    "a failed bounded patch should stop its owning turn")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "interrupted" },
  })
  equal(activity.state, "failed", "the bounded item should retain the patch-application failure")
  truthy(activity.error:find("did not apply", 1, true) ~= nil,
    "the terminal work item should explain that the accepted patch failed")
end

function tests.accepted_patch_preserves_edits_made_while_codex_applies_it()
  setup({ "local value = 1" })
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  seal.submit("update the value")
  local source_path = vim.api.nvim_buf_get_name(0)
  local changes = { {
    path = source_path,
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "modified-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 167,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "modified-patch" },
  })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local unsaved = true" })
  vim.fn.writefile({ "local value = 2" }, source_path)
  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "modified-patch", type = "fileChange", status = "completed", changes = changes },
  })
  vim.wait(50)
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local unsaved = true" },
    "patch refresh must not replace edits made after acceptance")
  truthy(seal._state.file_conflicts[vim.api.nvim_get_current_buf()] ~= nil,
    "the editor/disk divergence should remain latched for manual resolution")
end

function tests.rejecting_a_bounded_patch_stops_its_turn()
  setup({ "local value = 1" })
  seal.submit("patch: update the value")
  local activity = seal._state.activities[1]
  local changes = { {
    path = vim.api.nvim_buf_get_name(0),
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "rejected-bounded-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 168,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "rejected-bounded-patch" },
  })
  vim.fn.maparg("<Esc>", "n", false, true).callback()
  equal(response(fake, 168).result.decision, "decline", "the bounded patch should be rejected")
  equal(request(fake, "turn/interrupt").params.turnId, "main-turn",
    "rejecting a bounded patch should stop its owning turn")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "interrupted" },
  })
  equal(activity.state, "cancelled",
    "the bounded rejection flag should classify the interrupted turn as cancelled")
end

function tests.cancel_key_rejects_and_stops_a_bounded_patch_end_to_end()
  setup({ "local value = 1" })
  seal.submit("patch: update the value")
  local changes = { {
    path = vim.api.nvim_buf_get_name(0),
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "cancel-bounded-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 173,
    method = "item/fileChange/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "cancel-bounded-patch",
      availableDecisions = { "accept", "decline", "cancel" },
    },
  })
  vim.fn.maparg("x", "n", false, true).callback()
  equal(response(fake, 173).result.decision, "cancel",
    "x should send the advertised reject-and-stop decision")
  equal(request(fake, "turn/interrupt").params.turnId, "main-turn",
    "the cancel decision should also stop the bounded owner")
end

function tests.patch_patch_stops_only_after_the_accepted_patch_is_applied()
  setup({ "local value = 1" })
  vim.api.nvim_set_option_value("modified", false, { buf = 0 })
  seal.submit("patch: update the value")
  local activity = seal._state.activities[1]
  local source_path = vim.api.nvim_buf_get_name(0)
  local changes = {
    {
      path = source_path,
      kind = { type = "update" },
      diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
    },
  }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "bounded-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 151,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "bounded-patch" },
  })

  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal(fake.responses[#fake.responses].result.decision, "accept", "the bounded patch should use normal review")
  truthy(request(fake, "turn/interrupt") == nil, "acceptance must wait for app-server to apply the patch")

  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "bounded-patch", type = "fileChange", status = "completed", changes = changes },
  })
  equal(request(fake, "turn/interrupt").params, {
    threadId = "main-thread",
    turnId = "main-turn",
  }, "the applied patch should stop its owning turn immediately")

  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "interrupted" },
  })
  equal(activity.state, "done", "the expected post-apply interruption should be a successful result")
  equal(vim.tbl_count(seal._state.activities), 0, "an expected bounded interruption should finish cleanly")
end

function tests.second_bounded_patch_is_rejected_and_invalidates_the_first_review()
  setup({ "local value = 1" })
  vim.api.nvim_set_option_value("modified", false, { buf = 0 })
  seal.submit("patch: update one value")
  local activity = seal._state.activities[1]
  local source_path = vim.api.nvim_buf_get_name(0)
  local function propose(item_id, request_id, value)
    seal._notification("item/started", {
      threadId = "main-thread",
      turnId = "main-turn",
      item = {
        id = item_id,
        type = "fileChange",
        status = "inProgress",
        changes = {
          {
            path = source_path,
            kind = { type = "update" },
            diff = string.format("@@ -1 +1 @@\n-local value = 1\n+local value = %d", value),
          },
        },
      },
    })
    seal._server_request({
      id = request_id,
      method = "item/fileChange/requestApproval",
      params = {
        threadId = "main-thread",
        turnId = "main-turn",
        itemId = item_id,
        availableDecisions = { "accept", "decline", "cancel" },
      },
    })
  end

  propose("bounded-first", 161, 2)
  truthy(seal._state.reviews["161"] ~= nil, "the first patch should wait for review")
  propose("bounded-second", 162, 3)

  equal(response(fake, 162).result.decision, "decline", "Seal should reject the second patch")
  equal(response(fake, 161).result.decision, "decline", "the first review should become stale and be declined")
  truthy(seal._state.reviews["161"] == nil, "a stopped bounded turn must not leave an acceptable review")
  equal(request(fake, "turn/interrupt").params, {
    threadId = "main-thread",
    turnId = "main-turn",
  }, "a second patch should stop the root turn")

  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "interrupted" },
  })
  equal(activity.state, "failed", "violating the one-patch contract should fail the bounded work item")
end

function tests.bounded_v2_child_patch_inherits_review_and_stops_the_root_turn()
  setup({ "" })
  vim.api.nvim_set_option_value("modified", false, { buf = 0 })
  seal.submit("patch: extract the storage helper")
  seal._notification("item/completed", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = {
      id = "v2-child-activity",
      type = "subAgentActivity",
      agentThreadId = "bounded-child",
      agentPath = "reader",
      kind = "started",
    },
  })
  local changes = {
    {
      path = test_root .. "/storage.lua",
      kind = { type = "add" },
      diff = "@@ -0,0 +1 @@\n+return {}",
    },
  }
  seal._notification("item/started", {
    threadId = "bounded-child",
    turnId = "bounded-child-turn",
    item = { id = "bounded-child-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 163,
    method = "item/fileChange/requestApproval",
    params = {
      threadId = "bounded-child",
      turnId = "bounded-child-turn",
      itemId = "bounded-child-patch",
      availableDecisions = { "accept", "decline", "cancel" },
    },
  })
  truthy(seal._state.reviews["163"] ~= nil, "a V2 child patch should inherit the bounded review")
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  truthy(request(fake, "turn/interrupt") == nil, "the root should keep running until the child patch applies")
  seal._notification("item/completed", {
    threadId = "bounded-child",
    turnId = "bounded-child-turn",
    item = { id = "bounded-child-patch", type = "fileChange", status = "completed", changes = changes },
  })

  equal(request(fake, "turn/interrupt").params, {
    threadId = "main-thread",
    turnId = "main-turn",
  }, "an applied V2 child patch should stop the owning root turn")
end

function tests.bounded_turn_that_finishes_without_a_patch_fails()
  setup({ "local value = 1" })
  seal.submit("patch: update the value")
  local activity = seal._state.activities[1]
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  equal(activity.state, "failed", "bounded work should not succeed without its one applied patch")
end

function tests.numeric_work_ids_do_not_fall_through_to_legacy_kind_indexes()
  setup({ "", "" }, { activity = { interval_ms = 100000 } })
  seal.submit("run an agent turn")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: queued declaration")
  local declaration = seal._state.jobs[1]
  truthy(declaration and declaration.id ~= 1 and declaration.legacy_id == 1,
    "the fixture should create the legacy/unified ID collision")
  truthy(not seal.accept(1), "an agent's unified ID must not select a declaration through its legacy ID")
  truthy(seal._state.jobs[1] == declaration, "the colliding declaration should remain untouched")
  truthy(seal.reject(1), "reject should resolve the unified agent work item")
  truthy(seal._state.jobs[1] == declaration, "rejecting the agent ID must not cancel the declaration")
  seal.reject(declaration)
end

function tests.prompting_from_patch_review_targets_the_source_buffer()
  setup({ "local value = 1", "" })
  local source = vim.api.nvim_get_current_buf()
  local source_path = vim.api.nvim_buf_get_name(source)
  seal.submit("patch: update the value")
  fake.thread_status = { type = "active", activeFlags = {} }
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = {
      id = "patch-prompt",
      type = "fileChange",
      status = "inProgress",
      changes = {
        {
          path = source_path,
          kind = { type = "update" },
          diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
        },
      },
    },
  })
  local response_count = #fake.responses
  seal._server_request({
    id = 69,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "patch-prompt" },
  })
  local review = seal._state.reviews["69"]
  truthy(review and vim.api.nvim_get_current_buf() == review.view.buf, "the patch review should be current")
  equal(vim.bo.modifiable, false, "the patch review should remain read-only")

  local snapshot = seal._capture()
  equal(snapshot.buf, source, "a prompt opened from the review should capture the underlying source")
  seal.submit("fun: read the value", { snapshot = snapshot })
  equal(review.view, nil, "submitting should defer the patch review")
  equal(vim.api.nvim_get_current_buf(), source, "submitting should return to the source buffer")
  equal(vim.bo.modifiable, true, "Seal must not leave the source buffer read-only")
  equal(seal._state.jobs[1].snapshot.buf, source, "the declaration should belong to the source buffer")
  truthy(request(fake, "thread/fork") == nil, "the declaration should stay in the backing chat")
  equal(seal._state.jobs[1].thread_id, nil, "the declaration should wait for the active patch turn")

  seal.reject(seal._state.jobs[1])
  truthy(request(fake, "turn/interrupt") == nil, "rejecting a queued declaration should not interrupt the patch turn")
  seal.review(test_root)
  vim.fn.maparg("<Esc>", "n", false, true).callback()
end

function tests.unloaded_named_buffers_do_not_block_patch_review()
  setup({ "local source = true" })
  local target_path = test_root .. "/unloaded-target.lua"
  vim.fn.writefile({ "local target = true" }, target_path)
  local leftover = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(leftover, target_path)
  vim.api.nvim_buf_set_lines(leftover, 0, -1, false, { "stale unloaded text" })
  vim.api.nvim_set_option_value("modified", false, { buf = leftover })
  vim.cmd("silent bunload " .. leftover)
  truthy(vim.api.nvim_buf_is_valid(leftover) and not vim.api.nvim_buf_is_loaded(leftover),
    "the fixture should retain a valid unloaded buffer")

  seal.submit("update the unloaded target")
  local changes = { {
    path = target_path,
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local target = true\n+local target = false",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "unloaded-target-patch", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 169,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "unloaded-target-patch" },
  })
  truthy(seal._state.reviews["169"].warning == nil,
    "an unloaded :bdelete leftover should not be compared as an empty live buffer")
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal(response(fake, 169).result.decision, "accept",
    "an unloaded leftover should not block acceptance later in the review path")
end

function tests.unloading_a_target_during_review_does_not_permanently_block_acceptance()
  setup({ "local source = true" })
  vim.fn.mkdir(test_root, "p")
  local target_path = test_root .. "/unload-during-review.lua"
  vim.fn.writefile({ "local value = 1" }, target_path)
  local target = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(target, target_path)
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "local value = 1" })
  vim.api.nvim_set_option_value("modified", false, { buf = target })
  seal.submit("update the value")
  local changes = { {
    path = target_path,
    kind = { type = "update" },
    diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
  } }
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { id = "unload-during-review", type = "fileChange", status = "inProgress", changes = changes },
  })
  seal._server_request({
    id = 170,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "unload-during-review" },
  })
  vim.cmd("silent bunload " .. target)
  truthy(not vim.api.nvim_buf_is_loaded(target), "the reviewed target should be unloaded")
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal(response(fake, 170).result.decision, "accept",
    "an unchanged target that was unloaded during review should remain acceptable")
end

function tests.modified_review_target_is_saved_before_acceptance()
  setup({ "local value = 1" })
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  seal.submit("change this value")
  local source = vim.api.nvim_get_current_buf()
  local source_path = vim.api.nvim_buf_get_name(source)
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = {
      id = "patch-2",
      type = "fileChange",
      status = "inProgress",
      changes = {
        {
          path = source_path,
          kind = { type = "update" },
          diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
        },
      },
    },
  })
  seal._server_request({
    id = 52,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "patch-2" },
  })

  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "local user_value = 3" })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal(fake.responses[#fake.responses], {
    id = 52,
    result = { decision = "accept" },
  }, "Seal should approve after saving the local buffer")
  equal(vim.api.nvim_get_option_value("modified", { buf = source }), false, "the local changes should be saved first")
  equal(vim.fn.readfile(source_path), { "local user_value = 3" }, "saving must preserve the user's local edit")
  truthy(seal._state.reviews["52"] == nil, "the accepted review should close")
  vim.fn.delete(source_path)
end

function tests.external_review_target_change_remains_blocked()
  setup({ "local value = 1" })
  vim.fn.mkdir(test_root, "p")
  vim.cmd("silent write")
  local source_path = vim.api.nvim_buf_get_name(0)
  seal.submit("change this value")
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = {
      id = "patch-external",
      type = "fileChange",
      status = "inProgress",
      changes = {
        {
          path = source_path,
          kind = { type = "update" },
          diff = "@@ -1 +1 @@\n-local value = 1\n+local value = 2",
        },
      },
    },
  })
  seal._server_request({
    id = 68,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "patch-external" },
  })
  vim.fn.writefile({ "local external_value = 4" }, source_path)
  local accept = vim.fn.maparg("<Tab>", "n", false, true)
  truthy(type(accept.callback) == "function", "the initially safe review should offer acceptance")
  accept.callback()

  local review = seal._state.reviews["68"]
  truthy(review and review.warning, "an external disk change should still block approval")
  equal(#fake.responses, 0, "Seal must not approve over an external disk change")
  vim.fn.maparg("<Esc>", "n", false, true).callback()
  vim.fn.delete(source_path)
end

function tests.unsafe_patch_has_no_accept_mapping()
  setup({ "" })
  seal.submit("change a file")
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = {
      id = "patch-3",
      type = "fileChange",
      status = "inProgress",
      changes = {
        {
          path = "/tmp/outside-seal-project.lua",
          kind = { type = "add" },
          diff = "@@ -0,0 +1 @@\n+unsafe",
        },
      },
    },
  })
  seal._server_request({
    id = 53,
    method = "item/fileChange/requestApproval",
    params = { threadId = "main-thread", turnId = "main-turn", itemId = "patch-3", grantRoot = "/tmp" },
  })

  local review = seal._state.reviews["53"]
  truthy(review and review.warning, "broader write access should block acceptance")
  truthy(vim.fn.maparg("<Tab>", "n", false, true).callback == nil, "unsafe patches should not offer acceptance")
  vim.fn.maparg("<Esc>", "n", false, true).callback()
  equal(fake.responses[#fake.responses].result.decision, "decline", "unsafe patches should remain rejectable")
end

function tests.command_approvals_require_an_explicit_decision_by_default()
  local prompted = false
  setup({ "" }, {
    select = function(items, _, callback)
      prompted = true
      callback(items[2])
    end,
  })
  seal.submit("run the focused test")
  seal._server_request({
    id = 57,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "command-manual",
      command = "make test",
      availableDecisions = { "accept", "decline", "cancel" },
    },
  })
  truthy(prompted, "default command approvals should remain an explicit security decision")
  equal(response(fake, 57).result.decision, "decline",
    "the selected manual decision should be sent to app-server")
end

function tests.command_approvals_auto_accept_when_explicitly_enabled()
  setup({ "" }, {
    auto_approve_commands = true,
    select = function()
      fail("auto-approved commands must not open an input dialog")
    end,
  })
  seal.submit("run the focused test")
  seal._server_request({
    id = 58,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "command-auto",
      command = "make test",
      availableDecisions = { "accept", "decline", "cancel" },
    },
  })
  equal(fake.responses[#fake.responses], {
    id = 58,
    result = { decision = "accept" },
  }, "commands should auto-accept without weakening file-change review")

  seal._server_request({
    id = 60,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "command-session-auto",
      command = "make test",
      availableDecisions = { "acceptForSession", "decline" },
    },
  })
  equal(fake.responses[#fake.responses].result.decision, "acceptForSession", "Seal should honor the available accept form")
end

function tests.command_escalations_require_explicit_approval_even_when_commands_auto_accept()
  local prompts = {}
  setup({ "" }, {
    auto_approve_commands = true,
    select = function(items, opts, callback)
      table.insert(prompts, opts.prompt)
      callback(items[2])
    end,
  })
  seal.submit("run a command")

  for index, escalation in ipairs({
    { networkApprovalContext = { host = "example.com" } },
    { additionalPermissions = { fileSystem = { "/outside-workspace" } } },
  }) do
    local item_id = "command-escalation-" .. index
    seal._notification("item/started", {
      threadId = "main-thread",
      turnId = "main-turn",
      item = {
        id = item_id,
        type = "commandExecution",
        command = "make test",
        status = "inProgress",
      },
    })
    local params = vim.tbl_extend("force", {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = item_id,
      availableDecisions = { "accept", "decline", "cancel" },
    }, escalation)
    seal._server_request({
      id = 160 + index,
      method = "item/commandExecution/requestApproval",
      params = params,
    })
    equal(fake.responses[#fake.responses].result.decision, "decline",
      "capability escalation must not inherit ordinary command auto-approval")
  end

  equal(#prompts, 2, "each escalation should open an explicit approval prompt")
  truthy(prompts[1]:find("Network request:", 1, true), "network context should be visible")
  truthy(prompts[2]:find("Additional permissions:", 1, true), "additional permissions should be visible")
end

function tests.custom_bounded_prefix_declines_commands_that_require_approval()
  setup({ "local value = 1" }, {
    select = function()
      fail("bounded commands must not open an approval dialog")
    end,
  })
  seal.submit("patch: update the value")
  seal._server_request({
    id = 158,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "bounded-command",
      command = "make test",
      availableDecisions = { "accept", "decline", "cancel" },
    },
  })
  equal(fake.responses[#fake.responses], {
    id = 158,
    result = { decision = "decline" },
  }, "bounded turns should decline commands that cross the approval boundary")
  truthy(request(fake, "turn/interrupt") == nil, "a declined command should let Codex proceed to its one patch")
end

function tests.command_approval_warns_about_unpreviewed_writes()
  local approval_prompt
  setup({ "" }, {
    auto_approve_commands = false,
    select = function(items, opts, callback)
      approval_prompt = opts.prompt
      callback(items[1])
    end,
  })
  seal.submit("run the focused test")
  local command = "make test " .. string.rep("x", 180) .. " && remove-important-file"
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = {
      id = "command-1",
      type = "commandExecution",
      command = command,
      cwd = test_root,
      status = "inProgress",
    },
  })
  seal._server_request({
    id = 54,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "command-1",
      reason = "run the requested test",
      environmentId = "local-workspace",
      availableDecisions = { "accept", "decline", "cancel", "acceptForSession" },
    },
  })
  equal(fake.responses[#fake.responses], {
    id = 54,
    result = { decision = "accept" },
  }, "an explicitly accepted command should resume Codex")
  truthy(
    notifications[#notifications].message:find("without a patch preview", 1, true),
    "command approval should explain its weaker review boundary"
  )
  truthy(approval_prompt:find("remove-important-file", 1, true), "the approval must not truncate a dangerous suffix")
  truthy(approval_prompt:find(test_root, 1, true), "the approval should show the working directory")
  truthy(approval_prompt:find("local-workspace", 1, true), "the approval should show the execution environment")
  truthy(approval_prompt:find("run the requested test", 1, true), "the approval should show Codex's reason")
end

function tests.command_approval_honors_available_decisions()
  local labels
  setup({ "" }, {
    auto_approve_commands = false,
    select = function(items, _, callback)
      labels = vim.tbl_map(function(item)
        return item.label
      end, items)
      callback(items[1])
    end,
  })
  seal.submit("consider a command")
  seal._server_request({
    id = 57,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "command-2",
      command = "make test",
      availableDecisions = { "decline", "cancel", "acceptForSession" },
    },
  })
  equal(labels, { "Decline and continue", "Decline and stop the turn" }, "Seal should offer only safe advertised choices")
  equal(fake.responses[#fake.responses].result.decision, "decline", "the advertised decline should be sent unchanged")
end

function tests.dismissed_command_uses_the_advertised_cancel()
  setup({ "" }, {
    auto_approve_commands = false,
    select = function(_, _, callback)
      callback(nil)
    end,
  })
  seal.submit("consider a command")
  seal._server_request({
    id = 59,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      itemId = "command-3",
      command = "make test",
      availableDecisions = { "accept", "cancel" },
    },
  })
  equal(fake.responses[#fake.responses].result.decision, "cancel", "dismissing the dialog should use advertised cancel")
end

function tests.external_resolution_surfaces_the_next_patch_review()
  setup({ "" })
  seal.submit("make two changes")
  seal._state.live[second_root] = {
    root = second_root,
    thread_id = "second-thread",
    active_turn_id = "second-turn",
  }
  seal._state.owned_turns["second-turn"] = {
    root = second_root,
    thread_id = "second-thread",
  }
  for index = 1, 2 do
    local item_id = "queued-patch-" .. index
    local thread_id = index == 1 and "main-thread" or "second-thread"
    local turn_id = index == 1 and "main-turn" or "second-turn"
    local project = index == 1 and test_root or second_root
    seal._notification("item/started", {
      threadId = thread_id,
      turnId = turn_id,
      item = {
        id = item_id,
        type = "fileChange",
        status = "inProgress",
        changes = {
          {
            path = string.format("%s/queued-%d.lua", project, index),
            kind = { type = "add" },
            diff = "@@ -0,0 +1 @@\n+return true",
          },
        },
      },
    })
    seal._server_request({
      id = 60 + index,
      method = "item/fileChange/requestApproval",
      params = { threadId = thread_id, turnId = turn_id, itemId = item_id },
    })
  end
  truthy(seal._state.reviews["62"].view ~= nil, "the newest queued review should be visible")
  seal._notification("serverRequest/resolved", { requestId = 62 })
  truthy(vim.wait(500, function()
    local review = seal._state.reviews["61"]
    return review and review.view and vim.api.nvim_win_is_valid(review.view.win)
  end, 5), "external resolution should surface the next queued review")
  vim.fn.maparg("<Esc>", "n", false, true).callback()
end

function tests.seal_prompt_waits_for_a_tui_owned_turn()
  setup({ "" })
  seal.submit("establish the Seal turn")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  fake.thread_status = { type = "active", activeFlags = {} }
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "tui-turn", status = "inProgress" },
  })
  seal.submit("do not inherit the TUI policy")
  truthy(request(fake, "turn/steer") == nil, "Seal must not steer a turn whose review policy it did not establish")
  equal(fake.main_turn_count, 1, "the Seal prompt should wait for the TUI turn")
  equal(vim.tbl_count(seal._state.activities), 1, "the queued Seal prompt should remain visible")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "tui-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the Seal prompt should start after the TUI turn")
end

function tests.seal_owned_child_thread_can_request_patch_review()
  setup({ "" })
  vim.api.nvim_set_option_value("modified", false, { buf = 0 })
  seal.submit("delegate a focused change")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { type = "collabAgentToolCall", receiverThreadIds = { "child-thread" } },
  })
  seal._notification("thread/started", {
    thread = {
      id = "child-thread",
      parentThreadId = "main-thread",
      status = { type = "active", activeFlags = {} },
    },
  })
  seal._notification("turn/started", {
    threadId = "child-thread",
    turn = { id = "child-turn", status = "inProgress" },
  })
  seal._notification("item/started", {
    threadId = "child-thread",
    turnId = "child-turn",
    item = {
      id = "child-patch",
      type = "fileChange",
      status = "inProgress",
      changes = {
        {
          path = test_root .. "/child.lua",
          kind = { type = "add" },
          diff = "@@ -0,0 +1 @@\n+return true",
        },
      },
    },
  })
  seal._server_request({
    id = 55,
    method = "item/fileChange/requestApproval",
    params = { threadId = "child-thread", turnId = "child-turn", itemId = "child-patch" },
  })

  local review = seal._state.reviews["55"]
  truthy(review and review.root == test_root, "a Seal-owned child should inherit the main review root")
  vim.fn.maparg("<Esc>", "n", false, true).callback()
  equal(fake.responses[#fake.responses].result.decision, "decline", "child patches should use the same review decision")
end

function tests.unobserved_child_approval_fails_closed()
  setup({ "" })
  vim.api.nvim_set_option_value("modified", false, { buf = 0 })
  seal.submit("delegate immediately")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  seal._notification("item/started", {
    threadId = "racy-child",
    turnId = "racy-child-turn",
    item = {
      id = "racy-patch",
      type = "fileChange",
      status = "inProgress",
      changes = {
        {
          path = test_root .. "/racy.lua",
          kind = { type = "add" },
          diff = "@@ -0,0 +1 @@\n+return true",
        },
      },
    },
  })
  local response_count = #fake.responses
  seal._server_request({
    id = 58,
    method = "item/fileChange/requestApproval",
    params = { threadId = "racy-child", turnId = "racy-child-turn", itemId = "racy-patch" },
  })

  truthy(seal._state.reviews["58"] == nil, "parentThreadId alone must not claim a child for Seal")
  equal(#fake.responses, response_count, "an unverified child request should remain under its owning client")
end

function tests.unobserved_child_request_never_opens_a_review()
  setup({ "" })
  seal.submit("delegate immediately")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  local response_count = #fake.responses
  seal._server_request({
    id = 63,
    method = "item/fileChange/requestApproval",
    params = { threadId = "delayed-child", turnId = "delayed-turn", itemId = "delayed-patch" },
  })
  truthy(seal._state.reviews["63"] == nil, "an unobserved child must not inherit the current parent turn")
  equal(#fake.responses, response_count, "Seal should not answer an unknown child's request")
end

function tests.tui_owned_child_thread_is_not_claimed_by_seal()
  setup({ "" })
  seal.submit("establish the main thread")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "tui-turn", status = "inProgress" },
  })
  seal._notification("thread/started", {
    thread = {
      id = "tui-child-thread",
      parentThreadId = "main-thread",
      status = { type = "active", activeFlags = {} },
    },
  })
  seal._notification("turn/started", {
    threadId = "tui-child-thread",
    turn = { id = "tui-child-turn", status = "inProgress" },
  })
  local response_count = #fake.responses
  seal._server_request({
    id = 56,
    method = "item/fileChange/requestApproval",
    params = { threadId = "tui-child-thread", turnId = "tui-child-turn", itemId = "tui-child-patch" },
  })
  equal(#fake.responses, response_count, "the attached TUI should retain control of its child's approvals")
  truthy(seal._state.reviews["56"] == nil, "Seal should not open a review for a TUI-owned child")
end

function tests.declarations_run_fifo_on_the_shared_thread()
  setup({ "", "" })
  seal.submit("fun: first")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: second")
  equal(fake.main_turn_count, 1, "only the first declaration should start")
  truthy(request(fake, "thread/fork") == nil, "neither declaration should fork")
  equal(vim.tbl_count(seal._state.jobs), 2, "both declaration markers should remain visible")

  complete_declaration("function first() end")
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the second declaration should start after the first")
  equal(seal._state.jobs[1].phase, "ready", "the first preview should remain ready")
  equal(seal._state.jobs[2].phase, "generating", "the second declaration should now be active")
  complete_declaration("function second() end")
  equal(seal._state.jobs[2].phase, "ready", "the second declaration should produce its own preview")
  seal.reject(1)
  seal.reject(2)
end

function tests.failed_interrupt_keeps_cancelled_turn_requests_fail_closed()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  function fake:request(method, params, callback)
    if method == "turn/interrupt" then
      table.insert(self.requests, { method = method, params = params })
      callback(nil, { message = "interrupt transport failed" })
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: cancel safely")
  seal.reject(1)
  local response_count = #fake.responses
  seal._server_request({
    id = 165,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "main-turn",
      command = "send data elsewhere",
      availableDecisions = { "accept", "decline" },
    },
  })
  equal(#fake.responses, response_count + 1, "a request from the still-running cancelled turn must be answered")
  equal(fake.responses[#fake.responses].result.decision, "decline",
    "an interrupt failure must not restore the cancelled turn's approval authority")
  local reported = false
  for _, notification in ipairs(notifications) do
    if notification.message:find("interrupt transport failed", 1, true) then
      reported = true
    end
  end
  truthy(reported, "the interrupt failure should be visible")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "interrupted" },
  })
end

function tests.cancel_before_turn_start_response_waits_for_confirmed_ownership()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local held_turn
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_turn = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: cancel during startup")
  truthy(held_turn ~= nil, "the declaration turn response should be held")
  equal(seal._state.jobs[1].turn_id, nil, "the job should not know its turn ID yet")
  seal.reject(1)

  truthy(request(fake, "turn/interrupt") == nil, "startup cancellation must not guess an interrupt target")
  held_turn({ turn = { id = "late-turn" } })
  local interrupt = request(fake, "turn/interrupt")
  equal(interrupt.params.threadId, "main-thread", "confirmed cancellation should target the shared thread")
  equal(interrupt.params.turnId, "late-turn", "the response should provide the exact turn to interrupt")
  local interrupts = 0
  for _, item in ipairs(fake.requests) do
    if item.method == "turn/interrupt" then
      interrupts = interrupts + 1
    end
  end
  equal(interrupts, 1, "startup cancellation should send exactly one confirmed interrupt")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "late-turn", status = "interrupted" },
  })
  truthy(request(fake, "thread/unsubscribe") == nil, "cancellation must not detach the persistent thread")
end

function tests.turn_started_notification_waits_for_start_response_ownership()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local held_turn
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_turn = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: cancel from notification")
  local client_id = request(fake, "turn/start").params.clientUserMessageId
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = {
      id = "notification-turn",
      status = "inProgress",
      items = { { type = "userMessage", clientId = client_id } },
    },
  })
  equal(
    seal._state.jobs[1].turn_id,
    nil,
    "turn/started alone should not claim the declaration turn"
  )
  seal.reject(1)
  truthy(request(fake, "turn/interrupt") == nil, "an unconfirmed notification must not be interrupted")
  held_turn({ turn = { id = "notification-turn" } })
  equal(
    request(fake, "turn/interrupt").params.turnId,
    "notification-turn",
    "the matching start response should confirm the interrupt target"
  )
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "notification-turn", status = "interrupted" },
  })
end

function tests.thread_failure_clears_a_stale_settings_restore_block()
  setup({ "" })
  seal.submit("explain this file")
  local session = seal._state.live[test_root]
  session.settings_blocked = true
  session.blocked_restore = { approvalPolicy = "never" }
  seal._notification("thread/status/changed", {
    threadId = "main-thread",
    status = { type = "systemError" },
  })
  truthy(not session.settings_blocked, "a dead thread cannot satisfy an old settings restoration")
  equal(session.blocked_restore, nil, "resetting a dead thread should discard the stale restore target")
end

function tests.failed_agent_turn_reports_the_server_error()
  setup({ "" })
  seal.submit("perform a task")
  seal._notification("error", {
    threadId = "main-thread",
    turnId = "main-turn",
    error = { message = "tool execution exploded" },
  })
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "failed", error = { message = "tool execution exploded" } },
  })
  local surfaced = false
  for _, notification in ipairs(notifications) do
    if notification.message:find("tool execution exploded", 1, true) then
      surfaced = true
    end
  end
  truthy(surfaced, "a failed agent turn should surface the app-server error")
end

function tests.closed_shared_thread_clears_its_jobs()
  setup({ "", "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: interrupted by a closed thread")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: queued on the closed thread")
  local source = vim.api.nvim_get_current_buf()

  seal._notification("thread/closed", { threadId = "main-thread" })

  truthy(vim.tbl_isempty(seal._state.jobs), "a closed shared thread must not leave declaration jobs behind")
  equal(seal._state.spinner_timer, nil, "a closed thread should stop the last spinner")
  equal(seal._state.job_mappings[source], nil, "a closed thread should restore source-buffer mappings")
end

function tests.collocated_jobs_are_preserved_and_selected_newest_first()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: first")
  seal.submit("fun: second")
  equal(vim.tbl_count(seal._state.jobs), 2, "collocated jobs should both remain represented")
  equal(fake.main_turn_count, 1, "the second collocated prompt should remain queued")
  truthy(seal.reject(), "the cursor dispatcher should select a collocated job")
  truthy(seal._state.jobs[2] == nil, "the newest collocated job should be selected first")
  truthy(seal._state.jobs[1] ~= nil, "rejecting the newest job should reveal its older sibling")
  seal.reject(1)
end

function tests.spinner_renders_before_app_server_is_ready()
  setup({ "local before = true", "local between = true", "" }, { activity = { interval_ms = 100000 } })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A -- temporary<Esc>", true, false, true), "xt", false)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local held_start
  function fake:start(callback)
    held_start = callback
  end

  truthy(seal.submit("fun: add build logging"), "the declaration should submit while app-server starts")
  truthy(held_start ~= nil, "Seal should be waiting for app-server readiness")
  truthy(request(fake, "thread/start") == nil, "the app-server thread should not exist yet")
  local job = seal._state.jobs[1]
  truthy(job and job.phase == "generating", "the declaration job should exist immediately")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local marker = vim.api.nvim_buf_get_extmark_by_id(0, namespace, job.extmark, { details = true })
  local text = marker[3].virt_lines[1][1][1] .. marker[3].virt_lines[1][2][1]
  truthy(text:find("function · add build logging", 1, true), "the immediate spinner should summarize the request")
  truthy(seal._state.spinner_timer ~= nil, "the spinner animation should start before network readiness")

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Esc>", true, false, true), "xt", false)
  truthy(seal._state.jobs[1] == job, "entering insert mode during startup should preserve the spinner")
  vim.cmd("undo")
  truthy(vim.wait(500, function()
    return seal._state.jobs[1] == job
      and job.snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "an unrelated undo during startup should preserve and rebase the spinner")
  seal.reject(job.id)
end

function tests.insert_leave_noop_formatter_keeps_the_startup_spinner()
  setup({ "local value = 1", "" }, { activity = { interval_ms = 100000 } })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local held_start
  function fake:start(callback)
    held_start = callback
  end
  local format_count = 0
  local group = vim.api.nvim_create_augroup("SealInsertLeaveFormatterTest", { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = 0,
    once = true,
    callback = function(args)
      format_count = format_count + 1
      local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, lines)
    end,
  })

  seal.submit("fun: survive the formatter")
  local job = seal._state.jobs[1]
  truthy(held_start ~= nil and job ~= nil, "the declaration should wait with a visible spinner")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Esc>", true, false, true), "xt", false)

  equal(format_count, 1, "the InsertLeave formatter should run")
  truthy(vim.wait(500, function()
    return seal._state.jobs[1] == job
      and job.snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "an equivalent full-buffer formatter pass should preserve the startup spinner")
  vim.api.nvim_del_augroup_by_id(group)
  seal.reject(job.id)
end

function tests.agent_prompts_render_before_backend_is_ready()
  setup({ "local value = 1" }, { backend = "acp", activity = { interval_ms = 100000 } })
  local held_start
  function fake:start(callback)
    held_start = callback
  end

  truthy(seal.submit("explain the build logger"), "a normal agent prompt should submit")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local markers = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
  equal(#markers, 1, "an unprefixed prompt should immediately leave an progress marker")
  truthy(markers[1][4].virt_lines[1][2][1]:find("Gemini · explain the build logger", 1, true),
    "the marker should name the configured backend and summarize the prompt")
  truthy(seal._state.spinner_timer ~= nil, "an unprefixed prompt should animate during startup")
  local frame = markers[1][4].virt_lines[1][1][1]
  seal._tick_activity()
  markers = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
  truthy(markers[1][4].virt_lines[1][1][1] ~= frame, "the freeform startup marker should advance its frame")

  truthy(seal.submit("patch: fix the build logger"), "a patch prompt should submit")
  truthy(held_start ~= nil, "both prompts should be waiting on the same backend startup")
  equal(vim.tbl_count(seal._state.activities), 2, "both prompts should retain their lifecycle state")
  markers = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
  equal(#markers, 1, "collocated prompts should share one progress marker")
  local summary = markers[1][4].virt_lines[1][2][1]
  truthy(summary:find("patch · fix the build logger", 1, true), "the marker should show the prefixed request")
  truthy(summary:find("2 requests here", 1, true), "the request count should include the normal prompt")
  truthy(seal._state.spinner_timer ~= nil, "the prefixed prompt should animate while it waits")
  truthy(
    seal._state.job_mappings[vim.api.nvim_get_current_buf()] ~= nil,
    "agent markers should install the documented Esc cancellation dispatcher"
  )

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local edited = true" })
  seal._tick_activity()
  equal(vim.tbl_count(seal._state.activities), 2, "editing should not cancel informational markers")
  seal.stop()
  equal(vim.tbl_count(seal._state.activities), 0, "stopping Seal should remove informational markers")
  equal(vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}), {}, "stopping should remove progress markers")
  equal(seal._state.spinner_timer, nil, "stopping should stop the animation timer")
end

function tests.concurrent_initial_prompts_run_fifo()
  setup({ "local value = 1" }, { activity = { interval_ms = 100000 } })
  local held_start
  function fake:start(callback)
    held_start = callback
  end
  local original_request = fake.request
  local submission_count = 0
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      submission_count = submission_count + 1
      callback({ turn = { id = "submission-" .. submission_count } })
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("first startup prompt")
  seal.submit("second startup prompt")
  held_start(true)

  equal(submission_count, 1, "only the first startup prompt should be submitted")
  equal(vim.tbl_count(seal._state.activities), 2, "both startup prompts should keep their markers")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "submission-1", status = "inProgress" },
  })
  equal(seal._state.activities[1].turn_id, "submission-1", "turn/started should bind the active prompt")
  equal(seal._state.activities[2].turn_id, nil, "the queued prompt should remain unbound")
  truthy(seal._state.owned_turns["submission-1"] ~= nil, "the active turn should remain Seal-owned")

  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "submission-1", status = "completed" },
  })
  local second_started = vim.wait(1000, function()
    return submission_count == 2
  end, 5)
  truthy(second_started, "the second startup prompt should start after the first")
  equal(vim.tbl_count(seal._state.activities), 1, "the first completion should preserve the queued marker")
  equal(seal._state.activities[2].turn_id, "submission-2", "the queued marker should bind to its own turn")
  truthy(seal._state.owned_turns["submission-1"] == nil, "the completion should clear turn ownership")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "submission-2", status = "completed" },
  })
  equal(vim.tbl_count(seal._state.activities), 0, "the second completion should clear its marker")
end

function tests.session_read_failure_clears_immediate_agent_spinner()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local held_read
  function fake:request(method, params, callback)
    if method == "thread/read" then
      table.insert(self.requests, { method = method, params = params })
      held_read = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("explain this file")
  equal(vim.tbl_count(seal._state.activities), 1, "the marker should exist while session status loads")
  held_read(nil, { message = "status read failed" })
  equal(vim.tbl_count(seal._state.activities), 0, "a session read failure should remove the marker")
  equal(seal._state.spinner_timer, nil, "the failed request should stop the idle spinner timer")
end

function tests.app_server_start_failure_clears_immediate_spinners()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local held_start
  function fake:start(callback)
    held_start = callback
  end

  seal.submit("fun: add build logging")
  seal.submit("explain the build logger")
  equal(vim.tbl_count(seal._state.jobs), 1, "the declaration marker should render while startup is pending")
  equal(vim.tbl_count(seal._state.activities), 1, "the agent marker should render while startup is pending")
  held_start(false, { message = "app-server failed" })

  equal(vim.tbl_count(seal._state.jobs), 0, "startup failure should clear the declaration marker")
  equal(vim.tbl_count(seal._state.activities), 0, "startup failure should clear the agent marker")
  equal(seal._state.spinner_timer, nil, "startup failure should stop the idle spinner timer")
end

function tests.delayed_old_client_exit_preserves_restarted_activity()
  seal._reset()
  notifications = {}
  local project = test_root
  local transports = {}
  seal.setup({
    transport_factory = function(_, _, on_exit)
      local transport = {
        exit = on_exit,
        send = function()
          return true
        end,
        stop = function() end,
      }
      table.insert(transports, transport)
      return transport
    end,
    root = function()
      return project
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    keymaps = { prompt = false, chat = false },
    activity = { interval_ms = 100000 },
  })
  vim.cmd("enew!")
  buffer_sequence = buffer_sequence + 1
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_name(0, string.format("%s/restart-%d.lua", project, buffer_sequence))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1" })

  seal.submit("old request")
  equal(#transports, 1, "the first request should start the first client")
  seal.stop()
  seal.submit("new request")
  equal(#transports, 2, "a request after stop should start a new client")
  local _, activity = next(seal._state.activities)
  local restarted_loading = seal._state.loading[project]
  truthy(activity ~= nil and restarted_loading ~= nil, "the restarted request should be pending visibly")

  transports[1].exit(0, true)
  vim.wait(50, function()
    return false
  end, 5)

  equal(seal._state.activities[activity.id], activity, "the old exit callback must not clear the new marker")
  truthy(seal._state.loading[project] == restarted_loading, "the old session callback must not consume the new load")
  seal.stop()
end

function tests.status_batch_preserves_submission_order()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local held_read
  local reads = 0
  function fake:request(method, params, callback)
    if method == "thread/read" then
      reads = reads + 1
      if reads == 1 then
        table.insert(self.requests, { method = method, params = params })
        held_read = callback
        return
      end
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: stale pending declaration")
  local job = seal._state.jobs[1]
  truthy(job ~= nil, "the declaration should have an immediate marker")
  seal.submit("make a workspace change")
  equal(seal._state.jobs[1], job, "a Seal-started writable turn should preserve the pending declaration")

  held_read({
    thread = {
      id = "main-thread",
      cwd = test_root,
      status = { type = "idle" },
    },
  })
  truthy(request(fake, "thread/fork") == nil, "the preserved declaration should not fork")
  equal(job.thread_id, "main-thread", "the earlier declaration should start first on the shared thread")
  equal(fake.main_turn_count, 1, "the later agent prompt should remain queued")
  seal.reject(1)
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the later agent prompt should start after the declaration")
end

function tests.spinner_is_anchored_and_animates_in_place()
  setup({ "local value = 1" }, { activity = { interval_ms = 10 } })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  seal.submit("fun:   load   the saved state")
  local job = seal._state.jobs[1]
  truthy(job ~= nil, "declaration submission should create a job")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local before = vim.api.nvim_buf_get_extmark_by_id(0, namespace, job.extmark, { details = true })
  equal({ before[1], before[2] }, { 0, 6 }, "the spinner should stay at the captured cursor")
  local before_text = before[3].virt_lines[1][1][1] .. before[3].virt_lines[1][2][1]
  truthy(before_text:find("function · load the saved state", 1, true), "the spinner should summarize the prompt")
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  truthy(seal._state.jobs[1] ~= nil, "Tab should not accept a job that is still generating")
  truthy(notifications[#notifications].message:find("still generating", 1, true), "pending Tab should explain its state")

  local after
  local after_text
  truthy(vim.wait(1000, function()
    after = vim.api.nvim_buf_get_extmark_by_id(0, namespace, job.extmark, { details = true })
    after_text = after[3].virt_lines[1][1][1] .. after[3].virt_lines[1][2][1]
    return after_text ~= before_text
  end, 5), "the real spinner timer should advance the frame")
  equal({ after[1], after[2] }, { 0, 6 }, "animation must update the existing anchored extmark")

  local timer = seal._state.spinner_timer
  local extmark = job.extmark
  vim.fn.maparg("<Esc>", "n", false, true).callback()
  truthy(seal._state.jobs[1] == nil, "Esc should cancel the pending job under the cursor")
  equal(vim.api.nvim_buf_get_extmark_by_id(0, namespace, extmark, {}), {}, "cancellation should remove the marker")
  equal(vim.fn.timer_info(timer), {}, "the shared spinner timer should stop with the last running job")
end

function tests.mapping_away_from_marker_preserves_global_behavior()
  setup({ "", "move here now" }, { activity = { interval_ms = 100000 } })
  local calls = 0
  vim.keymap.set("n", "<Tab>", function()
    calls = calls + 1
    return "l"
  end, { expr = true })
  seal.submit("fun: stay on the first line")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("3<Tab>", true, false, true), "xt", false)
  truthy(vim.wait(500, function()
    return calls == 1 and vim.api.nvim_win_get_cursor(0)[2] == 3
  end, 5), "Tab away from a marker should preserve the global expression mapping and its count")
  truthy(seal._state.jobs[1] ~= nil, "Tab on another line must not accept or cancel the only Seal job")

  seal.reject(1)
  vim.keymap.del("n", "<Tab>")
end

function tests.escape_at_agent_markers_cancels_normal_and_patch_turns()
  for _, prompt in ipairs({ "explain this file", "patch: update this file" }) do
    setup({ "" }, { activity = { interval_ms = 100000 } })
    seal.submit(prompt)
    local escape = vim.fn.maparg("<Esc>", "n", false, true)
    truthy(type(escape.callback) == "function", "agent markers should install the documented cancel mapping")
    escape.callback()
    equal(vim.tbl_count(seal._state.activities), 0, "Esc should remove the selected agent marker")
    equal(request(fake, "turn/interrupt").params.turnId, "main-turn",
      "Esc should stop the selected agent turn")
    seal._notification("turn/completed", {
      threadId = "main-thread",
      turn = { id = "main-turn", status = "interrupted" },
    })
    local completion = notifications[#notifications]
    truthy(completion.message:find("turn cancelled", 1, true) ~= nil,
      "a deliberate interruption should be reported as cancellation")
    truthy(completion.level ~= vim.log.levels.ERROR,
      "a deliberate interruption must not produce an error notification")
  end
end

function tests.rejecting_one_queued_job_keeps_its_sibling()
  setup({ "", "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: first")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: second")

  truthy(seal.reject(1), "the first job should be rejected")
  local interrupt = request(fake, "turn/interrupt")
  equal(interrupt.params.threadId, "main-thread", "the active shared turn should be interrupted")
  equal(interrupt.params.turnId, "main-turn", "the selected turn should be interrupted")
  truthy(seal._state.jobs[2] ~= nil, "the queued sibling job should remain")
  equal(seal._state.spinner_timer, nil, "a queued sibling should remain visible without consuming animation ticks")
  seal.reject(2)
  local interrupt_count = 0
  for _, sent in ipairs(fake.requests) do
    if sent.method == "turn/interrupt" then
      interrupt_count = interrupt_count + 1
    end
  end
  equal(interrupt_count, 1, "rejecting the queued sibling should not send another interrupt")
end

function tests.multiple_jobs_share_and_restore_buffer_mappings()
  setup({ "", "" }, { activity = { interval_ms = 100000 } })
  local previous_tab = function() end
  local previous_escape = function() end
  vim.keymap.set("n", "<Tab>", previous_tab, { buffer = 0 })
  vim.keymap.set("n", "<Esc>", previous_escape, { buffer = 0 })

  seal.submit("fun: first")
  local seal_tab = vim.fn.maparg("<Tab>", "n", false, true).callback
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: second")
  equal(vim.fn.maparg("<Tab>", "n", false, true).callback, seal_tab, "the second job should reuse one dispatcher")

  seal.reject(1)
  equal(vim.fn.maparg("<Tab>", "n", false, true).callback, seal_tab, "the dispatcher should remain for one sibling")
  seal.reject(2)
  equal(vim.fn.maparg("<Tab>", "n", false, true).callback, previous_tab, "the original Tab mapping should be restored")
  equal(vim.fn.maparg("<Esc>", "n", false, true).callback, previous_escape, "the original Esc mapping should be restored")
end

function tests.closed_source_buffer_discards_ready_jobs_and_mappings()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local source = vim.api.nvim_get_current_buf()
  seal.submit("fun: close with the buffer")
  complete_declaration("function close_with_the_buffer() end")
  truthy(seal._state.jobs[1] ~= nil, "the ready job should exist before the buffer closes")

  vim.api.nvim_buf_delete(source, { force = true })

  truthy(seal._state.jobs[1] == nil, "BufDelete should discard a ready job")
  equal(seal._state.job_mappings[source], nil, "BufDelete should release the job mapping state")
end

function tests.mapping_installed_during_a_job_is_not_clobbered()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: pending")
  local newer_tab = function() end
  vim.keymap.set("n", "<Tab>", newer_tab, { buffer = 0 })
  seal.reject(1)
  equal(vim.fn.maparg("<Tab>", "n", false, true).callback, newer_tab, "Seal cleanup should preserve a newer mapping")
end

function tests.mapping_restoration_preserves_replace_keycodes()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local previous_tab = function()
    return "l"
  end
  vim.keymap.set("n", "<Tab>", previous_tab, {
    buffer = 0,
    expr = true,
    replace_keycodes = false,
  })
  equal(
    vim.fn.maparg("<Tab>", "n", false, true).replace_keycodes,
    nil,
    "the fixture should start with keycode replacement disabled"
  )

  seal.submit("fun: preserve the previous mapping")
  seal.reject(1)

  local restored = vim.fn.maparg("<Tab>", "n", false, true)
  equal(restored.callback, previous_tab, "Seal should restore the original expression callback")
  equal(restored.replace_keycodes, nil, "Seal should preserve replace_keycodes=false")
end

function tests.buffer_edit_reanchors_all_jobs()
  setup({ "", "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: first")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: second")

  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(other, test_root .. "/parallel-other.lua")
  vim.api.nvim_set_option_value("filetype", "lua", { buf = other })
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "" })
  seal.submit("fun: other buffer", { buf = other, cursor = { 1, 0 } })
  equal(vim.tbl_count(seal._state.jobs), 3, "all three jobs should be active")

  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local changed = true" })
  truthy(vim.wait(500, function()
    return vim.tbl_count(seal._state.jobs) == 3
      and seal._state.jobs[1].snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "the edit should reanchor every job in the buffer")
  truthy(seal._state.jobs[1] ~= nil, "the changed target's job should remain active")
  local first_position = vim.api.nvim_buf_get_extmark_by_id(
    0,
    vim.api.nvim_get_namespaces()["seal-activity"],
    seal._state.jobs[1].extmark,
    {}
  )
  equal(
    seal._state.jobs[1].snapshot.line,
    vim.api.nvim_buf_get_lines(0, first_position[1], first_position[1] + 1, false)[1],
    "the target snapshot should follow its reanchored marker"
  )
  truthy(seal._state.jobs[2] ~= nil, "an unchanged target in the same buffer should remain active")
  truthy(seal._state.jobs[3] ~= nil, "the other buffer's job should remain active")

  seal.reject(1)
  seal.reject(2)
  seal.reject(3)
  vim.api.nvim_buf_delete(other, { force = true })
end

function tests.deleting_every_line_keeps_buffer_reconciliation_usable()
  for _, direct_limit in ipairs({ 16, 0 }) do
    setup({ "only line" }, {
      activity = { interval_ms = 100000 },
      direct_reconcile_lines = direct_limit,
    })
    seal.submit("fun: survive an empty buffer")
    local job = seal._state.jobs[1]
    local model = seal._state.buffer_models[vim.api.nvim_get_current_buf()]
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})

    truthy(vim.wait(500, function()
      return seal._state.buffer_errors[job.snapshot.buf] == nil
        and vim.deep_equal(model:lines(), { "" })
    end, 5), "deleting all lines should reconcile the required empty buffer line")
    truthy(seal._state.jobs[1] == job, "the active request should remain usable after deleting all lines")
    complete_declaration("function survives_empty_buffer() end")
    truthy(seal.reject(job), "the reconciled request should remain actionable")
  end
end

function tests.deleting_a_prefix_that_leaves_a_real_blank_line_does_not_fake_an_empty_buffer()
  for _, fixture in ipairs({
    { direct_limit = 16, lines = { "remove", "" }, last = 1 },
    { direct_limit = 16, lines = vim.list_extend(vim.fn['repeat']({ "remove" }, 29), { "" }), last = 29 },
  }) do
    setup(fixture.lines, {
      activity = { interval_ms = 100000 },
      direct_reconcile_lines = fixture.direct_limit,
    })
    seal.submit("fun: keep the surviving blank line")
    local job = seal._state.jobs[1]
    local model = seal._state.buffer_models[job.snapshot.buf]
    vim.api.nvim_buf_set_lines(job.snapshot.buf, 0, fixture.last, false, {})

    truthy(vim.wait(500, function()
      return seal._state.buffer_errors[job.snapshot.buf] == nil
        and vim.deep_equal(model:lines(), { "" })
    end, 5), "a surviving blank line must not be inserted into the model twice")
    seal.reject(job)
  end
end

function tests.deleting_marked_line_keeps_and_reanchors_job()
  setup({ "local before = true", "local remove_me = true", "local after = true" }, {
    activity = { interval_ms = 100000 },
  })
  vim.api.nvim_win_set_cursor(0, { 2, 6 })
  seal.submit("fun: survives deletion of its marked line")
  local job = seal._state.jobs[1]

  vim.api.nvim_buf_set_lines(0, 1, 2, false, {})

  truthy(vim.wait(500, function()
    return seal._state.jobs[1] == job
      and job.snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "deleting the marked line should keep the running job")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local position = vim.api.nvim_buf_get_extmark_by_id(0, namespace, job.extmark, {})
  equal(position, { 1, 0 }, "the marker should move to the deletion boundary")
  equal(job.snapshot.line, "local after = true", "the target snapshot should follow the moved marker")
  truthy(request(fake, "turn/interrupt") == nil, "deleting the marked line should not interrupt Codex")

  complete_declaration("function survives_marked_line_deletion() end")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  truthy(not seal.accept(), "the first acceptance should explicitly resolve the deleted anchor")
  truthy(seal.accept(), "the rebased declaration should remain acceptable")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "local before = true",
    "function survives_marked_line_deletion() end",
    "local after = true",
  }, "accepting should insert at the deletion boundary without replacing nearby code")
end

function tests.insert_mode_away_from_marker_keeps_and_reanchors_job()
  setup({ "local before = true", "local between = true", "" }, { activity = { interval_ms = 100000 } })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  seal.submit("fun: survives unrelated insert mode")
  local job = seal._state.jobs[1]

  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Esc>", true, false, true), "xt", false)
  truthy(seal._state.jobs[1] == job, "entering and leaving insert mode at the marker should not cancel it")

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("O-- editing while Seal works<Esc>", true, false, true),
    "xt",
    false
  )
  truthy(vim.wait(500, function()
    return seal._state.jobs[1] == job
      and job.snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "an insert-mode edit away from the marker should rebase the running job")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local position = vim.api.nvim_buf_get_extmark_by_id(0, namespace, job.extmark, {})
  equal(position[1], 3, "the marker should follow a line inserted above it")

  complete_declaration("function survives_unrelated_insert_mode() end")
  vim.api.nvim_win_set_cursor(0, { position[1] + 1, 0 })
  truthy(seal.accept(), "the rebased result should still be acceptable")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "-- editing while Seal works",
    "local before = true",
    "local between = true",
    "function survives_unrelated_insert_mode() end",
  }, "accepting should preserve the concurrent insert-mode edit")
end

function tests.undo_away_from_marker_keeps_job()
  setup({ "local before = true", "local between = true", "" }, { activity = { interval_ms = 100000 } })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A -- temporary<Esc>", true, false, true), "xt", false)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  seal.submit("fun: survives unrelated undo")
  local job = seal._state.jobs[1]

  vim.cmd("undo")

  truthy(vim.wait(500, function()
    return seal._state.jobs[1] == job
      and job.snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "undo away from the marker should rebase the running job")
  equal(vim.api.nvim_buf_get_lines(0, 0, 1, false), { "local before = true" }, "the unrelated edit should undo")
  seal.reject(1)
end

function tests.editing_selected_context_keeps_job()
  setup({ "local selected = true", "local more = true", "" }, { activity = { interval_ms = 100000 } })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  seal.submit("fun: uses the selected context", { range = 2, line1 = 1, line2 = 2 })
  truthy(seal._state.jobs[1] ~= nil, "the selected-context job should start")

  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local selected = false" })

  truthy(vim.wait(500, function()
    return seal._state.jobs[1] ~= nil
      and seal._state.jobs[1].snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "editing selected context should keep and reanchor the job")
  truthy(seal._state.jobs[1].snapshot.selection == nil, "edited selection text should not remain as queued context")
  seal.reject(1)
end

function tests.new_thread_interrupts_and_detaches_old_thread()
  setup({ "" })
  seal.submit("first prompt")
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { type = "collabAgentToolCall", receiverThreadIds = { "old-child-thread" } },
  })
  seal._notification("turn/started", {
    threadId = "old-child-thread",
    turn = { id = "old-child-turn", status = "inProgress" },
  })
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
  local response_count = #fake.responses
  seal._server_request({
    id = 96,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "old-child-thread",
      turnId = "old-child-turn",
      command = "make test",
      availableDecisions = { "accept", "decline" },
    },
  })
  equal(#fake.responses, response_count, "a replacement thread must not approve a late old-child command")
  seal._notification("serverRequest/resolved", { threadId = "old-child-thread", requestId = 96 })
end

function tests.new_thread_serializes_with_an_inflight_session_start()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local starts = {}
  function fake:request(method, params, callback)
    if method == "thread/start" then
      table.insert(self.requests, { method = method, params = params })
      table.insert(starts, callback)
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("prompt while the session starts")
  equal(#starts, 1, "the prompt should begin one project thread")
  seal.new_thread()
  equal(#starts, 1, ":SealNew must wait for the in-flight project thread response")

  starts[1]({ thread = { id = "superseded-thread", status = { type = "idle" } } })
  equal(#starts, 2, "the replacement should start only after the first load is resolved and detached")
  starts[2]({ thread = { id = "replacement-thread", status = { type = "idle" } } })
  equal(seal._state.live[test_root].thread_id, "replacement-thread",
    "the replacement response should be the only live project session")
  equal(vim.tbl_count(seal._state.activities), 0,
    "work submitted to the explicitly replaced session should be cancelled")
end

function tests.prompt_waits_for_the_replacement_thread_started_by_seal_new()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local replacement_start
  local start_count = 0
  function fake:request(method, params, callback)
    if method == "thread/start" then
      table.insert(self.requests, { method = method, params = params })
      start_count = start_count + 1
      replacement_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.new_thread()
  truthy(replacement_start ~= nil, ":SealNew should begin the replacement request")
  seal.submit("wait for the explicit replacement")
  equal(start_count, 1,
    "a prompt during the replacement round-trip must not start a competing thread")
  truthy(request(fake, "turn/start") == nil,
    "the prompt should remain behind the replacement loading slot")

  replacement_start({
    thread = { id = "replacement-thread", status = { type = "idle" } },
    model = "gpt-test",
    modelProvider = "openai",
    reasoningEffort = "high",
  })
  truthy(vim.wait(500, function()
    local turn = request(fake, "turn/start")
    return turn and turn.params.threadId == "replacement-thread"
  end, 5), "the waiting prompt should dispatch only on the replacement thread")
  equal(seal._state.live[test_root].thread_id, "replacement-thread",
    "the replacement should remain the sole live session")
end

complete_declaration = function(code)
  local session = seal._state.live[test_root]
  local entry = session and session.current
  local thread_id = session and session.thread_id or "main-thread"
  local turn_id = entry and entry.turn_id or "main-turn"
  seal._notification("item/completed", {
    threadId = thread_id,
    turnId = turn_id,
    item = { type = "agentMessage", phase = "final_answer", text = vim.json.encode({ code = code }) },
  })
  seal._notification("turn/completed", {
    threadId = thread_id,
    turnId = turn_id,
    turn = { id = turn_id, status = "completed" },
  })
  vim.wait(1000, function()
    for _, job in pairs(seal._state.jobs) do
      if job.thread_id == thread_id and job.turn_id == turn_id then
        return job.phase == "ready"
      end
    end
    return true
  end)
end

function tests.early_result_replays_after_late_start_response()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local held_turn
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_turn = callback
      return
    end
    return original_request(self, method, params, callback)
  end

  seal.submit("fun: finish before the response")
  local client_id = request(fake, "turn/start").params.clientUserMessageId
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = {
      id = "main-turn",
      status = "inProgress",
      items = { { type = "userMessage", clientId = client_id } },
    },
  })
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { type = "collabAgentToolCall", receiverThreadIds = { "already-completed-child" } },
  })
  local response_count = #fake.responses
  seal._server_request({
    id = 98,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "already-completed-child",
      turnId = "already-completed-child-turn",
      command = "make test",
      availableDecisions = { "accept", "decline" },
    },
  })
  complete_declaration("function finish_before_the_response() end")
  truthy(seal._state.jobs[1] and seal._state.jobs[1].phase == "generating",
    "unbound notifications should wait for confirmed ownership")
  held_turn({ turn = { id = "main-turn" } })
  truthy(vim.wait(1000, function()
    return seal._state.jobs[1] and seal._state.jobs[1].phase == "ready"
  end, 5), "the buffered result should replay after the start response")
  equal(request(fake, "turn/interrupt"), nil, "a delayed start response must not interrupt a completed turn")
  equal(#fake.responses, response_count, "a known-completed turn must not replay its buffered child approval")
  seal._notification("serverRequest/resolved", { threadId = "already-completed-child", requestId = 98 })
  seal.reject(1)
end

function tests.queued_jobs_dispatch_in_their_own_buffers()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local first_buf = vim.api.nvim_get_current_buf()
  seal.submit("fun: first buffer declaration")

  local second_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(second_buf, test_root .. "/parallel-second-buffer.lua")
  vim.api.nvim_set_option_value("filetype", "lua", { buf = second_buf })
  vim.api.nvim_buf_set_lines(second_buf, 0, -1, false, { "" })
  seal.submit("fun: second buffer declaration", { buf = second_buf, cursor = { 1, 0 } })
  complete_declaration("function first_buffer_declaration() end")
  complete_declaration("function second_buffer_declaration() end")

  vim.api.nvim_set_current_buf(second_buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal(
    vim.api.nvim_buf_get_lines(second_buf, 0, -1, false),
    { "function second_buffer_declaration() end" },
    "Tab should accept only the marker in the current buffer"
  )
  truthy(seal._state.jobs[1] ~= nil, "accepting the second buffer must preserve the first buffer's job")

  vim.api.nvim_set_current_buf(first_buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal(
    vim.api.nvim_buf_get_lines(first_buf, 0, -1, false),
    { "function first_buffer_declaration() end" },
    "the first buffer should accept its own marker independently"
  )
  truthy(vim.tbl_isempty(seal._state.jobs), "both buffer-local jobs should be finished")
  vim.api.nvim_buf_delete(second_buf, { force = true })
end

function tests.failed_freeform_preflight_keeps_other_buffer_preview()
  setup({ "local before = true" }, { save_before_agent = true, activity = { interval_ms = 100000 } })
  local source = vim.api.nvim_get_current_buf()
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(source, path)
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(other, test_root .. "/preflight-preview.lua")
  vim.api.nvim_set_option_value("filetype", "lua", { buf = other })
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "" })
  seal.submit("fun: keep this preview", { buf = other, cursor = { 1, 0 } })
  complete_declaration("function keep_this_preview() end")
  local job = seal._state.jobs[1]
  truthy(job and job.phase == "ready", "the other buffer should have a ready preview")

  local group = vim.api.nvim_create_augroup("SealFailedFreeformPreflightTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = source,
    callback = function(args)
      vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { "local after = true" })
      vim.api.nvim_set_option_value("modified", false, { buf = args.buf })
    end,
  })
  seal.submit("make a workspace change")

  local main_turns = 0
  for _, item in ipairs(fake.requests) do
    if item.method == "turn/start" and item.params.threadId == "main-thread" then
      main_turns = main_turns + 1
    end
  end
  equal(main_turns, 1, "the failed workspace-writing prompt should not start another turn")
  equal(seal._state.jobs[1], job, "a failed freeform preflight should preserve an unrelated ready preview")

  seal.reject(1)
  vim.api.nvim_del_augroup_by_id(group)
  vim.api.nvim_buf_delete(other, { force = true })
  vim.fn.delete(path)
end

function tests.sequential_results_can_be_accepted_independently()
  setup({ "", "local between = true", "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: first declaration")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  seal.submit("fun: second declaration")

  complete_declaration("function first_declaration()\n  return true\nend")
  equal(seal._state.jobs[1].phase, "ready", "the first result should become ready first")
  equal(seal._state.jobs[2].phase, "generating", "the second result should start next")
  complete_declaration("function second_declaration() end")
  equal(seal._state.jobs[2].phase, "ready", "the second result should become independently ready")
  equal(seal._state.spinner_timer, nil, "the timer should stop when every job is ready")

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  truthy(seal._state.jobs[1] == nil, "Tab should accept the ready result under the cursor")
  local second = seal._state.jobs[2]
  truthy(second ~= nil, "accepting the upper result should preserve a non-overlapping sibling")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local second_position = vim.api.nvim_buf_get_extmark_by_id(0, namespace, second.extmark, {})
  equal(second_position[1], 4, "the lower result should reanchor after a multi-line insertion above it")
  equal(
    second.snapshot.changedtick,
    vim.api.nvim_buf_get_changedtick(0),
    "the sibling should be rebased during the accepted buffer edit"
  )

  vim.api.nvim_win_set_cursor(0, { second_position[1] + 1, 0 })
  vim.cmd("SealAccept")
  truthy(seal._state.jobs[2] == nil, ":SealAccept should accept the rebased result under the cursor")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "function first_declaration()",
    "  return true",
    "end",
    "local between = true",
    "function second_declaration() end",
  }, "both independent declarations should be inserted at their marked locations")
  equal(vim.tbl_count(seal._state.jobs), 0, "accepting both results should clear both jobs")
  equal(seal._state.job_mappings[vim.api.nvim_get_current_buf()], nil, "buffer mappings should restore after the last job")
end

function tests.accepted_multiline_preview_moves_collocated_siblings_after_it()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: older declaration")
  seal.submit("fun: newer declaration")
  complete_declaration("function older_declaration() end")
  complete_declaration("function newer_declaration()\n  return true\nend")
  local older = seal._state.jobs[1]
  local newer = seal._state.jobs[2]

  truthy(seal.accept(newer), "the chosen collocated multi-line preview should be accepted")
  equal(older.snapshot.row, 3, "the sibling should move to the boundary after the inserted declaration")
  truthy(not older.snapshot.anchor_ambiguous, "a controlled Seal insertion should resolve the sibling exactly")

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  truthy(seal.accept(), "the EOF marker should accept the remaining sibling without inserting inside the function")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "function newer_declaration()",
    "  return true",
    "end",
    "function older_declaration() end",
  }, "collocated declarations should remain peers after sequential acceptance")
end

function tests.collocated_acceptance_preserves_a_siblings_existing_ambiguity()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: older ambiguous declaration")
  seal.submit("fun: newer resolved declaration")
  complete_declaration("function older_ambiguous() end")
  complete_declaration("function newer_resolved()\n  return true\nend")
  local older = seal._state.jobs[1]
  local newer = seal._state.jobs[2]

  vim.api.nvim_buf_set_lines(0, 0, 1, false, { " " })
  truthy(older.snapshot.anchor_ambiguous and newer.snapshot.anchor_ambiguous,
    "the user replacement should make both collocated locations ambiguous")
  truthy(not seal.accept(newer), "the newer item should require its own explicit re-anchor")
  truthy(not newer.snapshot.anchor_ambiguous and older.snapshot.anchor_ambiguous,
    "re-anchoring one item must not resolve its sibling")
  truthy(seal.accept(newer), "the explicitly resolved newer preview should be accepted")
  equal(older.snapshot.row, 3, "the ambiguous sibling marker should still move after the inserted declaration")
  truthy(older.snapshot.anchor_ambiguous,
    "controlled relocation must preserve ambiguity that predates the accepted preview")

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  truthy(not seal.accept(older), "the older sibling must still require its own first-Tab confirmation")
  truthy(seal.accept(older), "the independently confirmed sibling should then be accepted")
end

function tests.acceptance_finalizes_when_sibling_reconciliation_fails()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: older retained declaration")
  seal.submit("fun: newer accepted declaration")
  complete_declaration("function older_retained() end")
  complete_declaration("function newer_accepted()\n  return true\nend")
  local older = seal._state.jobs[1]
  local newer = seal._state.jobs[2]
  local model = seal._state.buffer_models[vim.api.nvim_get_current_buf()]
  local original_reconcile_edit = model.reconcile_edit
  model.reconcile_edit = function()
    error("forced acceptance reconcile failure")
  end
  local accepted = seal.accept(newer)
  model.reconcile_edit = original_reconcile_edit

  truthy(accepted, "the successful editor insertion should still finalize its accepted work item")
  truthy(seal._state.jobs[2] == nil and newer.state == "done",
    "a sibling model failure must not strand the accepted item in applying")
  truthy(seal._state.jobs[1] == older, "the sibling should remain retained behind the sticky model error")
  truthy(seal._state.buffer_errors[older.snapshot.buf] ~= nil,
    "the stale sibling model should remain blocked until a full reconciliation")
  vim.cmd("doautocmd BufReadPost")
  seal.reject(older)
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

function tests.automatic_declarations_preserve_edits_and_separate_undo_steps()
  setup({ "  ", "local existing = true" }, { auto_accept_declarations = true })
  local global_undo = vim.go.undolevels
  seal.submit("fun: load it")
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { "local existing = false" })
  complete_declaration("function load()\n  return true\nend")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "  function load()", "    return true", "  end", "local existing = false",
  }, "the declaration should insert automatically and preserve the intervening edit")
  equal(vim.tbl_count(seal._state.jobs), 0, "automatic insertion should retire its job")
  equal(seal._state.preview, nil, "successful insertion should leave no acceptance UI")
  equal(vim.go.undolevels, global_undo, "automatic insertion must not change global undo settings")
  for _, notification in ipairs(notifications) do
    truthy(not notification.message:find("Tab accepts", 1, true), "automatic results should not request acceptance")
  end
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "local existing = later_edit" })
  vim.cmd("undo")
  equal(vim.api.nvim_buf_get_lines(0, 0, 1, false), { "  function load()" },
    "undoing later typing should preserve the generated declaration")
  vim.cmd("undo")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "  ", "local existing = false" },
    "one more undo should remove only the automatic insertion")
  vim.cmd("undo")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "  ", "local existing = true" },
    "the earlier user edit should retain its own undo history")
end

function tests.automatic_declarations_apply_without_switching_back_to_the_source()
  setup({ "" }, { auto_accept_declarations = true })
  local source = vim.api.nvim_get_current_buf()
  seal.submit("fun: finish in the background")
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "local elsewhere = true" })
  vim.api.nvim_win_set_buf(0, other)
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  local tick = vim.api.nvim_buf_get_changedtick(other)
  complete_declaration("function finished() end")
  equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), { "function finished() end" },
    "a result should insert into its original buffer without an acceptance step")
  equal(vim.api.nvim_get_current_buf(), other, "automatic insertion must not steal focus")
  equal(vim.api.nvim_win_get_cursor(0), { 1, 6 }, "automatic insertion must not move the active cursor")
  equal(vim.api.nvim_buf_get_changedtick(other), tick, "automatic insertion must not edit the active buffer")
  equal(seal._state.preview, nil, "a hidden source buffer should not retain a successful preview")
end

function tests.automatic_declarations_rebase_collocated_queued_results()
  setup({ "" }, { auto_accept_declarations = true })
  seal.submit("fun: first")
  seal.submit("fun: second")
  complete_declaration("function first()\n  return true\nend")
  truthy(vim.wait(1000, function() return fake.main_turn_count == 2 end, 5), "the queued request should start")
  complete_declaration("function second() end")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "function first()", "  return true", "end", "function second() end",
  }, "queued results at one cursor should both insert in order")
  equal(vim.tbl_count(seal._state.jobs), 0, "both automatic jobs should finish")
end

function tests.automatic_declarations_leave_conflicts_for_resolution()
  for _, conflict in ipairs({ "disk", "ambiguous", "readonly" }) do
    setup({ "local target = true", "local after = true" }, { auto_accept_declarations = true })
    local path = vim.api.nvim_buf_get_name(0)
    vim.cmd("silent write")
    seal.submit("fun: keep conflicts safe")
    if conflict == "disk" then
      vim.fn.writefile({ "changed elsewhere" }, path)
    elseif conflict == "ambiguous" then
      vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    else
      vim.bo.modifiable = false
    end
    local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    complete_declaration("function should_wait() end")
    equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), before, "automatic insertion must preserve a " .. conflict .. " conflict")
    truthy(seal._state.preview ~= nil, "a conflicting result should remain available for resolution")
    if conflict == "ambiguous" then
      truthy(seal._state.preview.snapshot.anchor_ambiguous, "automatic insertion must not guess a new anchor")
    else
      truthy(seal._state.preview.preview_blocked_reason ~= nil, "the preview should explain why insertion was blocked")
    end
    vim.bo.modifiable = true
    seal.reject()
    vim.fn.delete(path)
  end
end

function tests.reject_leaves_buffer_untouched()
  setup({ "" })
  seal.submit("fun: stored state")
  complete_declaration("function stored_state() end")
  truthy(seal.reject(), "reject should clear the preview")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "" }, "reject must not edit the buffer")
end

function tests.freeform_preserves_an_existing_preview()
  setup({ "" })
  seal.submit("fun: focused change")
  complete_declaration("function focused_change() end")
  truthy(seal._state.preview ~= nil, "declaration preview should exist before the freeform prompt")
  seal.submit("make a broader change")
  truthy(seal._state.preview ~= nil, "a Seal-started writable turn should preserve the pending preview")
  seal.reject(1)
end

function tests.patch_preserves_queued_declaration_spinners()
  setup({ "", "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: log the build process")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("type: represent build output")
  local first = seal._state.jobs[1]
  local second = seal._state.jobs[2]

  seal.submit("patch: connect build logging")
  equal(vim.tbl_count(seal._state.jobs), 2, "patch submission should preserve both declaration spinners")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  equal(seal._state.jobs[1], first, "the function spinner should survive the patch turn start")
  equal(seal._state.jobs[2], second, "the type spinner should survive the patch turn start")

  seal.reject(1)
  seal.reject(2)
end

function tests.patch_patch_reload_preserves_unaffected_previews()
  setup({ "local build = true", "", "local output = {}", "" }, { activity = { interval_ms = 100000 } })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: log the build process")
  complete_declaration("function log_build() end")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  seal.submit("type: represent build output")
  complete_declaration("BuildOutput = {}")
  local first = seal._state.jobs[1]
  local second = seal._state.jobs[2]
  truthy(first and first.phase == "ready" and second and second.phase == "ready", "both previews should be ready")

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  seal.submit("patch: add a build-file header")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "inProgress" },
  })
  vim.fn.writefile({ "-- patch change", "local build = true", "", "local output = {}", "" }, path)
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })

  truthy(vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "-- patch change"
      and seal._state.jobs[1] == first
      and seal._state.jobs[2] == second
      and first.phase == "ready"
      and second.phase == "ready"
  end, 5), "an unrelated patch patch should reload without discarding either preview")
  local namespace = vim.api.nvim_get_namespaces()["seal-activity"]
  local first_position = vim.api.nvim_buf_get_extmark_by_id(0, namespace, first.extmark, {})
  local second_position = vim.api.nvim_buf_get_extmark_by_id(0, namespace, second.extmark, {})
  equal(first_position[1], 2, "the function preview should follow the inserted header")
  equal(second_position[1], 4, "the type preview should follow the inserted header")

  seal.reject(1)
  seal.reject(2)
  vim.fn.delete(path)
end

function tests.attached_tui_turn_preserves_an_existing_preview()
  setup({ "" })
  seal.submit("fun: focused change")
  complete_declaration("function focused_change() end")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "tui-turn", status = "inProgress" },
  })
  truthy(seal._state.preview ~= nil, "a TUI-started turn should not discard an unchanged pending preview")
  seal.reject(1)
end

function tests.external_file_change_blocks_preview_acceptance()
  setup({ "" })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  seal.submit("fun: stale on disk")
  complete_declaration("function stale_on_disk() end")
  vim.fn.writefile({ "local changed_externally = true" }, path)
  truthy(not seal.accept(), "a preview based on an externally changed file must not be accepted")
  truthy(seal._state.preview ~= nil, "the externally stale preview should remain available after reload")
  vim.fn.delete(path)
end

function tests.external_file_change_retains_a_blocked_preview()
  setup({ "" })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  seal.submit("fun: stale before preview")
  vim.fn.writefile({ "local changed_externally = true" }, path)
  complete_declaration("function stale_before_preview() end")
  truthy(seal._state.preview ~= nil, "an externally stale result should remain blocked until reload")
  truthy(seal._state.preview.preview_blocked_reason ~= nil, "the retained preview should explain the disk conflict")
  vim.fn.delete(path)
end

function tests.identical_writes_do_not_invalidate_a_preview()
  setup({ "" })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  seal.submit("fun: survives autosave")
  vim.cmd("silent write")
  complete_declaration("function survives_autosave() end")
  truthy(seal._state.preview ~= nil, "an identical write should not discard an in-flight declaration")
  vim.cmd("silent write")
  truthy(seal.accept(), "an identical write should not invalidate a visible preview")
  vim.fn.delete(path)
end

function tests.buffer_rename_blocks_preview_rendering()
  setup({ "" })
  seal.submit("fun: stale after rename")
  vim.api.nvim_buf_set_name(0, test_root .. "/renamed-before-preview.lua")
  complete_declaration("function stale_after_rename() end")
  truthy(seal._state.preview == nil, "a result for the old buffer path must not be rendered")
end

function tests.buffer_rename_blocks_preview_acceptance()
  setup({ "" })
  seal.submit("fun: stale after rename")
  complete_declaration("function stale_after_rename() end")
  vim.api.nvim_buf_set_name(0, test_root .. "/renamed-after-preview.lua")
  truthy(not seal.accept(), "a preview for the old buffer path must not be accepted")
  truthy(seal._state.preview == nil, "the renamed preview should be cleared")
end

function tests.completion_text_change_keeps_generation()
  setup({ "" })
  seal.submit("fun: survives completion")
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "completed text" })
  truthy(vim.wait(500, function()
    return seal._state.generation ~= nil
      and seal._state.generation.snapshot.changedtick == vim.api.nvim_buf_get_changedtick(0)
  end, 5), "completion-menu edits should reanchor declaration generation")
  local job = seal._state.generation
  local position = vim.api.nvim_buf_get_extmark_by_id(
    0,
    vim.api.nvim_get_namespaces()["seal-activity"],
    job.extmark,
    {}
  )
  equal(job.snapshot.row, position[1], "the completion snapshot should follow its marker")
  truthy(request(fake, "turn/interrupt") == nil, "editing the marked line should not interrupt Codex")
  complete_declaration("function survives_completion() end")
  truthy(seal._state.preview ~= nil, "the completed declaration should still reach preview")
  seal.reject(1)
end

function tests.result_follows_local_edits()
  setup({ "" })
  seal.submit("fun: follows edits")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
  complete_declaration("function follows_edits() end")
  truthy(seal._state.preview ~= nil, "a locally edited buffer should still receive a preview")
  truthy(not seal.accept(), "an ambiguous in-line replacement should require re-anchoring")
  truthy(seal.accept(), "the rebased preview should remain acceptable at its logical marker")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "function follows_edits() end",
    "changed",
  }, "accepting should preserve the local edit")
end

function tests.python_type_alias_reaches_preview_by_default()
  setup({ "" })
  vim.bo.filetype = "python"
  vim.api.nvim_buf_set_name(0, test_root .. "/storage_types.py")
  seal.submit("type: represent values stored on disk")
  complete_declaration("StorageValue: TypeAlias = dict[str, str]")

  truthy(seal._state.preview ~= nil, "a Python type-alias expression should reach the manual preview")
  seal.reject()
end

function tests.multiple_declarations_are_rejected()
  setup({ "" }, { validate_declarations = true })
  seal.submit("fun: too many")
  complete_declaration("function one() end\nfunction two() end")
  vim.wait(1000, function()
    return seal._state.generation == nil
  end)
  truthy(seal._state.preview == nil, "multiple declarations must not be previewed")
  truthy(notifications[#notifications].message:find("expected one declaration", 1, true), "rejection should explain the syntax-unit count")
end

function tests.wrong_declaration_kind_is_rejected()
  setup({ "" }, { validate_declarations = true })
  seal.submit("fun: not actually a function")
  complete_declaration("local value = 1")
  vim.wait(1000, function()
    return seal._state.generation == nil
  end)
  truthy(seal._state.preview == nil, "the wrong declaration kind must not be previewed")
  truthy(notifications[#notifications].message:find("expected a function", 1, true), "kind rejection should be explicit")
end

function tests.wrapper_with_multiple_functions_is_rejected()
  setup({ "" }, { validate_declarations = true })
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
  setup({ "" }, { validate_declarations = true })
  vim.bo.filetype = "javascript"
  if not optional_parser("javascript", "javascript_arrow_function_is_accepted") then
    return
  end
  local snapshot = seal._capture()
  local valid, reason = seal._validate_declaration(snapshot, { "const load = () => true;" }, "function")
  truthy(valid, reason or "a JavaScript arrow function should validate as one function")
end

function tests.interface_equivalents_are_accepted()
  setup({ "" }, { validate_declarations = true })
  if optional_parser("rust", "interface_equivalents_are_accepted[rust]") then
    vim.bo.filetype = "rust"
    local snapshot = seal._capture()
    local rust_valid, rust_reason = seal._validate_declaration(snapshot, {
      "pub trait Storage {",
      "    fn load(&self, key: &str) -> String;",
      "}",
    }, "interface")
    truthy(rust_valid, rust_reason or "a Rust trait should satisfy an interface request")
  end

  if optional_parser("go", "interface_equivalents_are_accepted[go]") then
    vim.bo.filetype = "go"
    local snapshot = seal._capture()
    local go_valid, go_reason = seal._validate_declaration(snapshot, {
      "type Storage interface {",
      "    Load(key string) string",
      "}",
    }, "interface")
    truthy(go_valid, go_reason or "a Go interface declaration should validate through its type wrapper")
  end
end

function tests.failed_editor_apply_keeps_the_canonical_preview()
  setup({ "" })
  seal.submit("fun: survive an editor textlock")
  complete_declaration("function survives_textlock() end")
  local job = seal._state.jobs[1]
  local original_set_lines = vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function()
    error("simulated textlock")
  end
  local accepted = seal.accept(job)
  vim.api.nvim_buf_set_lines = original_set_lines

  truthy(not accepted, "an editor write failure must not report acceptance")
  truthy(seal._state.jobs[1] == job, "the failed write must retain the exact canonical item")
  equal(job.state, "preview", "failed applying must return to preview state")
  equal(job.phase, "ready", "the retained preview should remain interactive")
  truthy(job.preview ~= nil and job.raw_code ~= nil, "the retained item should keep its model payload")
  truthy(job.apply_blocked_reason:find("simulated textlock", 1, true), "the preview should explain the failed write")

  truthy(seal.accept(job), "the same retained preview should be retryable")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "function survives_textlock() end" },
    "the retry should insert the original proposal")
end

function tests.ready_preview_reindents_from_raw_output_after_an_edit()
  setup({ "  ", "  local existing = true" })
  seal.submit("fun: follow the enclosing indentation")
  complete_declaration("function indented()\n  return true\nend")
  local job = seal._state.jobs[1]
  equal(job.lines[1], "  function indented()", "the initial preview should use the original indentation")

  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "    " })
  equal(job.lines[1], "    function indented()", "a ready preview should be regenerated from raw code")
  truthy(job.raw_code:find("function indented", 1, true), "raw model output should remain indentation-neutral")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  truthy(not seal.accept(job), "changing the anchor line should require one explicit re-anchor")
  truthy(seal.accept(job), "the re-anchored preview should remain acceptable")
  equal(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "    function indented()",
    "acceptance should use the refreshed indentation")
end

function tests.same_line_markers_dispatch_by_column()
  setup({ "abcdefgh" }, { activity = { interval_ms = 100000 } })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  seal.submit("fun: first column")
  local first = seal._state.jobs[1]
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  seal.submit("type: second column")
  local second = seal._state.jobs[2]

  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  truthy(seal.reject(), "the dispatcher should find the exact first-column marker")
  truthy(not seal._state.jobs[1] and seal._state.jobs[2] == second,
    "rejecting the first column must preserve the newer marker elsewhere on the line")
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  truthy(seal.reject(), "the second-column marker should remain independently selectable")
  truthy(first.cancelled and second.cancelled, "both canonical items should record their own cancellation")
end

function tests.collocated_ready_and_blocked_jobs_remain_actionable()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: first ready proposal")
  seal.submit("fun: second blocked proposal")
  seal.submit("fun: third queued proposal")
  local first = seal._state.jobs[1]
  local second = seal._state.jobs[2]
  local third = seal._state.jobs[3]
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local changed = true" })
  complete_declaration("function first_ready() end")
  local session = seal._state.live[test_root]
  truthy(vim.wait(1000, function()
    return session.preflight_blocked == second.id
  end, 5), "the second ambiguous request should block before dispatch")

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  truthy(not seal.accept(), "the ready proposal should be selected first and re-anchored")
  truthy(seal.accept(), "the ready proposal should remain selected for acceptance")
  truthy(seal._state.jobs[1] == nil, "accepting the ready proposal should reveal the blocked request")
  truthy(seal._state.jobs[2] == second and seal._state.jobs[3] == third,
    "collocation must preserve the blocked and queued siblings")

  vim.api.nvim_win_set_cursor(0, { second.snapshot.row + 1, second.snapshot.column })
  truthy(not seal.accept(), "Tab on the revealed blocked request should re-anchor rather than apply")
  truthy(session.preflight_blocked == nil, "re-anchoring the blocked request should release the project gate")
  truthy(second.state == "starting" or second.state == "running", "the blocked request should resume its own turn")
  seal.reject(second)
  seal.reject(third)
end

function tests.deleted_final_line_reanchors_to_the_eof_boundary()
  setup({ "local keep = true", "local delete_me = true" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  seal.submit("fun: append after the surviving line")
  vim.api.nvim_buf_set_lines(0, 1, 2, false, {})
  complete_declaration("function appended_at_eof() end")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  truthy(not seal.accept(), "the final-line deletion should require explicit EOF re-anchoring")
  equal(seal._state.jobs[1].snapshot.row, 1, "the cursor fallback should preserve the logical EOF boundary")
  truthy(seal.accept(), "the EOF-anchored preview should remain acceptable")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
    "local keep = true",
    "function appended_at_eof() end",
  }, "acceptance should append after the final survivor")
end

function tests.global_mapping_changes_are_resolved_at_dispatch_time()
  setup({ "", "away" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: keep the temporary dispatcher")
  local calls = 0
  vim.keymap.set("n", "<Tab>", function()
    calls = calls + 1
    return ""
  end, { expr = true })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  equal(calls, 1, "Seal should dispatch to the current global mapping, not a captured stale mapping")
  seal.reject(1)
  vim.keymap.del("n", "<Tab>")
end

function tests.pending_limit_bounds_retained_context()
  setup({ "" }, { max_pending_items = 3, activity = { interval_ms = 100000 } })
  local held_start
  function fake:start(callback)
    held_start = callback
  end
  truthy(seal.submit("fun: one"), "the first request should be admitted")
  truthy(seal.submit("fun: two"), "the second request should be admitted")
  truthy(seal.submit("fun: three"), "the request at the limit should be admitted")
  truthy(not seal.submit("fun: four"), "work beyond the configured project limit should be rejected")
  equal(vim.tbl_count(seal._state.items), 3, "rejected work must not retain a snapshot or anchor")
  truthy(notifications[#notifications].message:find("3 pending requests", 1, true), "the limit should be explained")
  truthy(held_start ~= nil, "the admitted work should still be waiting on the app-server")
  seal.stop()
end

function tests.blocked_agent_retries_in_fifo_order_after_save()
  setup({ "local source = true" }, { save_before_agent = false, activity = { interval_ms = 100000 } })
  vim.fn.mkdir(test_root, "p")
  local other = vim.api.nvim_create_buf(true, false)
  local other_path = test_root .. "/seal-blocked-retry.lua"
  vim.fn.delete(other_path)
  vim.api.nvim_buf_set_name(other, other_path)
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "local dirty = true" })

  seal.submit("first blocked prompt")
  local first = seal._state.activities[1]
  equal(first.state, "blocked", "the dirty-project preflight should retain a blocked item")
  truthy(request(fake, "turn/start") == nil, "blocked work must not reach Codex")
  seal.submit("second queued prompt")
  local second = seal._state.activities[2]
  equal(second.state, "queued", "a sibling should wait behind the blocked chat turn")

  vim.api.nvim_buf_call(other, function()
    vim.cmd("silent write")
  end)
  local started = request(fake, "turn/start")
  truthy(started ~= nil, "saving the blocking buffer should retry automatically")
  equal(started.params.input[1].text, "first blocked prompt", "retry must preserve FIFO chat order")
  equal(first.state, "running", "the original canonical item should own the retried turn")
  equal(second.state, "queued", "the sibling must not overtake the retried prompt")

  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "completed" },
  })
  truthy(vim.wait(1000, function()
    return fake.main_turn_count == 2
  end, 5), "the sibling should start only after the retried turn completes")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn-2", status = "completed" },
  })
  vim.api.nvim_buf_delete(other, { force = true })
  vim.fn.delete(other_path)
end

function tests.one_hundred_marks_share_one_fast_buffer_model()
  local lines = {}
  for index = 1, 100 do
    lines[index] = "local value_" .. index .. " = " .. index
  end
  setup(lines, { max_pending_items = 100, activity = { interval_ms = 100000 } })
  local buf = vim.api.nvim_get_current_buf()
  for index = 1, 100 do
    truthy(seal.submit("fun: request " .. index, { buf = buf, cursor = { index, 0 } }),
      "every request up to the limit should be admitted")
  end
  equal(vim.tbl_count(seal._state.jobs), 100, "all marks should remain canonical and independently addressable")
  equal(#seal._state.buffer_models[buf]:ids(), 100, "one shared model should own all buffer anchors")
  equal(vim.tbl_count(seal._state.animated_items), 1, "only the leased turn should animate")
  equal(#seal._state.live[test_root].scheduler:queue_ids(), 99,
    "the remaining requests should stay as static FIFO IDs")

  local original_diff = vim.diff
  local diff_calls = 0
  vim.diff = function(...)
    diff_calls = diff_calls + 1
    return original_diff(...)
  end
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- inserted above every mark" })
  vim.diff = original_diff
  equal(diff_calls, 0, "an ordinary edit should use the changed-slice path without a repository-sized diff")
  equal(vim.tbl_count(seal._state.jobs), 100, "one edit must not drop any of the hundred marks")
  equal(seal._state.jobs[100].snapshot.row, 100, "the final anchor should shift exactly once")
  equal(vim.tbl_count(seal._state.animated_items), 1, "rebasing must not animate queued markers")
  seal.stop()
  equal(vim.tbl_count(seal._state.items), 0, "stopping an in-flight queue should purge retired canonical items")
end

function tests.reconcile_failure_blocks_acceptance_until_a_clean_reload()
  setup({ "" })
  seal.submit("fun: survive a reconcile failure")
  complete_declaration("function reconciled() end")
  local job = seal._state.jobs[1]
  local model = seal._state.buffer_models[vim.api.nvim_get_current_buf()]
  local original_reconcile_edit = model.reconcile_edit
  model.reconcile_edit = function()
    error("forced reconcile failure")
  end
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local changed = true" })
  model.reconcile_edit = original_reconcile_edit
  truthy(seal._state.buffer_errors[job.snapshot.buf] ~= nil, "the buffer model failure should be sticky")
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- another edit" })
  truthy(seal._state.buffer_errors[job.snapshot.buf] ~= nil,
    "later incremental edits must not clear a missed-revision error")
  equal(model:lines(), { "" }, "the stale model should not partially consume a later edit")
  truthy(not seal.accept(job), "a stale model must fail closed")
  truthy(seal._state.jobs[1] == job, "fail-closed acceptance should retain the preview")

  vim.cmd("doautocmd BufReadPost")
  truthy(seal._state.buffer_errors[job.snapshot.buf] == nil, "a successful full reconciliation should clear the block")
  if job.snapshot.anchor_ambiguous then
    truthy(not seal.accept(job), "recovery should still require explicit resolution of an ambiguous anchor")
  end
  truthy(seal.accept(job), "the same preview should be acceptable after clean reconciliation")
end

function tests.delayed_settings_restore_cannot_mutate_a_reset_scheduler()
  setup({ "" })
  local original_request = fake.request
  local held_restore
  function fake:request(method, params, callback)
    if method == "thread/settings/update" then
      table.insert(self.requests, { method = method, params = params })
      held_restore = callback
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("fun: close while restoring settings")
  truthy(held_restore ~= nil, "the declaration should have a pending settings restoration")
  seal._notification("thread/closed", { threadId = "main-thread" })
  local session = seal._state.live[test_root]
  local reset_scheduler = session.scheduler
  local ok, callback_error = pcall(held_restore, {})
  truthy(ok, "a delayed restore callback must be ignored after reset: " .. tostring(callback_error))
  truthy(session.scheduler == reset_scheduler, "the stale callback must not replace or drive the reset scheduler")
  truthy(not session.settings_blocked, "the reset session must not inherit stale restore state")
end

function tests.cancelled_running_item_retires_until_its_lease_finishes()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  seal.submit("fun: cancel after dispatch")
  local job = seal._state.jobs[1]
  local session = seal._state.live[test_root]
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "main-turn",
    item = { type = "collabAgentToolCall", receiverThreadIds = { "cancelled-running-child" } },
  })
  seal._notification("turn/started", {
    threadId = "cancelled-running-child",
    turn = { id = "cancelled-running-child-turn", status = "inProgress" },
  })
  truthy(seal.reject(job), "the visible job should disappear immediately")
  truthy(seal._state.jobs[1] == nil, "retirement should remove the UI index")
  truthy(seal._state.items[job.id] == job and job.retired,
    "the scheduler lease should retain the canonical terminal object")
  truthy(session.scheduler:validate(), "retirement should preserve scheduler invariants")
  local response_count = #fake.responses
  seal._server_request({
    id = 97,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "cancelled-running-child",
      turnId = "cancelled-running-child-turn",
      command = "make test",
      availableDecisions = { "accept", "decline" },
    },
  })
  equal(#fake.responses, response_count + 1,
    "canceling a running item must answer its child's command request fail-closed")
  equal(fake.responses[#fake.responses].result.decision, "decline",
    "a cancelled child must not retain command authority")

  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "main-turn", status = "interrupted" },
  })
  truthy(vim.wait(500, function()
    return seal._state.items[job.id] == nil
  end, 5), "turn completion plus authoritative settings restoration should purge the retired object")
  truthy(session.scheduler:validate(), "the released scheduler should remain valid")
  seal._notification("serverRequest/resolved", { threadId = "cancelled-running-child", requestId = 97 })
end

function tests.early_server_request_replays_only_after_turn_confirmation()
  setup({ "" }, { auto_approve_commands = true })
  local original_request = fake.request
  local held_start
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("run the focused check")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "early-owned-turn", status = "inProgress" },
  })
  local response_count = #fake.responses
  seal._server_request({
    id = 90,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "early-owned-turn",
      command = "make test",
      availableDecisions = { "accept", "decline" },
    },
  })
  equal(#fake.responses, response_count, "ownership-unknown requests should wait for the start response")
  held_start({ turn = { id = "early-owned-turn" } })
  equal(fake.responses[#fake.responses], { id = 90, result = { decision = "accept" } },
    "confirmed agent ownership should replay the buffered request")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "early-owned-turn", status = "completed" },
  })
end

function tests.nonretryable_start_failure_discards_buffered_turn_events()
  setup({ "" })
  local original_request = fake.request
  local held_start
  function fake:request(method, params, callback)
    if method == "turn/start" then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("start a turn that fails")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "orphaned-start-event", status = "inProgress" },
  })
  local session = seal._state.live[test_root]
  truthy(next(session.scheduler.pending_turn_events) ~= nil, "the early event should be buffered before the response")
  held_start(nil, { message = "request was rejected" })
  equal(next(session.scheduler.pending_turn_events), nil,
    "a terminal start failure must discard events that can no longer be correlated")
  equal(next(session.unbound_turns or {}), nil, "the failed attempt must clear its unbound-turn index")
end

function tests.resolved_request_deduplication_is_bounded()
  setup({ "" })
  for request_id = 1, 1100 do
    seal._notification("serverRequest/resolved", { requestId = request_id })
  end
  equal(vim.tbl_count(seal._state.resolved_requests), 1024,
    "resolved request deduplication should retain only its bounded recent window")
  truthy(seal._state.resolved_requests["1"] == nil and seal._state.resolved_requests["1100"],
    "the bounded window should expire the oldest request IDs first")
end

function tests.buffered_collab_ownership_replays_an_exact_child_request()
  setup({ "" }, { auto_approve_commands = true })
  local original_request = fake.request
  local held_start
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("delegate a focused check")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "parent-race-turn", status = "inProgress" },
  })
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "parent-race-turn",
    item = { type = "collabAgentToolCall", receiverThreadIds = { "exact-child-thread" } },
  })

  local response_count = #fake.responses
  seal._server_request({
    id = 92,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "exact-child-thread",
      turnId = "exact-child-turn",
      command = "make test",
      availableDecisions = { "accept", "decline" },
    },
  })
  seal._server_request({
    id = 94,
    method = "mcpServer/elicitation/request",
    params = { threadId = "exact-child-thread" },
  })
  equal(#fake.responses, response_count, "a child request must wait for exact parent ownership")

  held_start({ turn = { id = "parent-race-turn" } })
  truthy(vim.wait(500, function()
    return #fake.responses == response_count + 2
  end, 5), "the exact collab receiver should replay after parent ownership is confirmed")
  equal(fake.responses[response_count + 1], { id = 92, result = { decision = "accept" } },
    "the replayed child command should use the owning agent turn's policy")
  equal(fake.responses[response_count + 2], { id = 94, result = { action = "decline" } },
    "exact child ownership should also correlate requests that omit a best-effort turn ID")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "parent-race-turn", status = "completed" },
  })
end

function tests.cancelled_start_never_replays_an_early_server_request()
  setup({ "" }, { activity = { interval_ms = 100000 } })
  local original_request = fake.request
  local held_start
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("fun: cancel before ownership")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "cancelled-early-turn", status = "inProgress" },
  })
  seal._notification("item/started", {
    threadId = "main-thread",
    turnId = "cancelled-early-turn",
    item = { type = "collabAgentToolCall", receiverThreadIds = { "cancelled-child-thread" } },
  })
  local response_count = #fake.responses
  seal._server_request({
    id = 91,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "main-thread",
      turnId = "cancelled-early-turn",
      availableDecisions = { "accept", "decline" },
    },
  })
  seal._server_request({
    id = 93,
    method = "item/commandExecution/requestApproval",
    params = {
      threadId = "cancelled-child-thread",
      turnId = "cancelled-child-turn",
      command = "make test",
      availableDecisions = { "accept", "decline" },
    },
  })
  seal.reject(1)
  held_start({ turn = { id = "cancelled-early-turn" } })
  equal(#fake.responses, response_count + 1, "a canceled item must answer its buffered command fail-closed")
  equal(response(fake, 91).result.decision, "decline", "the cancelled parent command should be declined")
  vim.wait(20)
  equal(#fake.responses, response_count + 2, "a canceled parent must answer its observed child fail-closed")
  equal(response(fake, 93).result.decision, "decline", "the cancelled child command should be declined")
  equal(request(fake, "turn/interrupt").params.turnId, "cancelled-early-turn",
    "the exact confirmed canceled turn should be interrupted")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "cancelled-early-turn", status = "interrupted" },
  })
  seal._notification("serverRequest/resolved", { threadId = "cancelled-child-thread", requestId = 93 })
end

function tests.external_settings_before_start_response_become_restore_target()
  setup({ "" })
  local original_request = fake.request
  local held_start
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("fun: preserve newer TUI settings")
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "never",
      approvalsReviewer = "auto_review",
      sandboxPolicy = { type = "readOnly", networkAccess = false },
      activePermissionProfile = vim.NIL,
    },
  })
  held_start({ turn = { id = "main-turn" } })
  local restore = request(fake, "thread/settings/update")
  equal(restore.params.approvalPolicy, "never", "a mixed update may deliberately keep the restrictive policy")
  equal(restore.params.approvalsReviewer, "auto_review", "restore should preserve the newer reviewer")
  equal(restore.params.sandboxPolicy, { type = "readOnly", networkAccess = false },
    "a mixed update may deliberately keep the read-only sandbox")
  complete_declaration("function preserves_newer_settings() end")
  seal.reject(1)
end

function tests.inflight_restore_converges_on_the_latest_external_settings()
  setup({ "" })
  local original_request = fake.request
  local restore_callbacks = {}
  function fake:request(method, params, callback)
    if method == "thread/settings/update" then
      table.insert(self.requests, { method = method, params = params })
      table.insert(restore_callbacks, callback)
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("fun: preserve settings changed during restore")
  equal(#restore_callbacks, 1, "the declaration should begin its first restore")
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "on-request",
      approvalsReviewer = "auto_review",
      sandboxPolicy = { type = "dangerFullAccess" },
      activePermissionProfile = vim.NIL,
    },
  })
  restore_callbacks[1]({})
  equal(#restore_callbacks, 1, "an enqueue acknowledgement must wait for its authoritative settings event")
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "untrusted",
      approvalsReviewer = "user",
      sandboxPolicy = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
      activePermissionProfile = vim.NIL,
    },
  })
  equal(#restore_callbacks, 2, "the delayed self-issued A event should release the queued B restore")
  local second_restore = request(fake, "thread/settings/update")
  equal(second_restore.params.approvalPolicy, "on-request", "the second restore should use the newest policy")
  equal(second_restore.params.approvalsReviewer, "auto_review", "the second restore should use the newest reviewer")

  restore_callbacks[2]({})
  equal(#restore_callbacks, 2, "the B acknowledgement must also wait for B's settings event")
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "on-request",
      approvalsReviewer = "auto_review",
      sandboxPolicy = { type = "dangerFullAccess" },
      activePermissionProfile = vim.NIL,
    },
  })
  equal(#restore_callbacks, 2, "the delayed A event must not be mistaken for a third external restore")

  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "untrusted",
      approvalsReviewer = "user",
      sandboxPolicy = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
      activePermissionProfile = vim.NIL,
    },
  })
  local session = seal._state.live[test_root]
  equal(session.settings.approvalPolicy, "untrusted", "local session state should converge on the final policy")
  equal(session.settings.approvalsReviewer, "user", "local session state should converge on the final reviewer")
  equal(#restore_callbacks, 2, "a later external A should win without another Seal write")
  complete_declaration("function converges_settings() end")
  seal.reject(1)
end

function tests.settings_restore_clears_a_stale_permission_profile()
  setup({ "" })
  local original_request = fake.request
  local held_restore
  function fake:request(method, params, callback)
    if method == "thread/settings/update" then
      table.insert(self.requests, { method = method, params = params })
      held_restore = callback
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("fun: clear a stale permission profile")
  truthy(held_restore ~= nil, "the declaration should begin restoring its thread settings")
  local session = seal._state.live[test_root]
  session.settings.activePermissionProfile = { id = "stale-profile" }
  held_restore({})
  equal(session.settings.activePermissionProfile.id, "stale-profile",
    "the enqueue acknowledgement alone must not claim that the profile was cleared")
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "untrusted",
      approvalsReviewer = "user",
      sandboxPolicy = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
      activePermissionProfile = vim.NIL,
    },
  })
  equal(session.settings.activePermissionProfile, nil,
    "a sandbox restore must not report convergence while a named permission profile remains active")
  complete_declaration("function clears_stale_profile() end")
  seal.reject(1)
end

function tests.external_completion_during_restore_does_not_revive_busy_state()
  setup({ "" })
  local original_request = fake.request
  local held_start
  local held_restore
  local held_restore_params
  local restore_count = 0
  function fake:request(method, params, callback)
    if method == "turn/start" and params.threadId == "main-thread" and not held_start then
      table.insert(self.requests, { method = method, params = params })
      held_start = callback
      return
    elseif method == "thread/settings/update" then
      restore_count = restore_count + 1
      if restore_count == 1 then
        table.insert(self.requests, { method = method, params = params })
        held_restore = callback
        held_restore_params = params
      else
        return original_request(self, method, params, callback)
      end
      return
    end
    return original_request(self, method, params, callback)
  end
  seal.submit("fun: retry after external completion")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "external-race-turn", status = "inProgress" },
  })
  seal._notification("thread/settings/updated", {
    threadId = "main-thread",
    threadSettings = {
      approvalPolicy = "never",
      approvalsReviewer = "user",
      sandboxPolicy = { type = "readOnly", networkAccess = false },
      activePermissionProfile = vim.NIL,
    },
  })
  held_start(nil, { message = "thread already has an active turn" })
  local session = seal._state.live[test_root]
  equal(session.external_turn_id, "external-race-turn", "the retry should wait for the external turn")
  truthy(held_restore ~= nil, "the failed declaration start should be restoring settings")
  seal._notification("turn/completed", {
    threadId = "main-thread",
    turn = { id = "external-race-turn", status = "completed" },
  })
  equal(session.external_turn_id, nil, "completion should clear the external owner during restore")
  held_restore({})
  seal._notification("thread/settings/updated", {
    threadId = held_restore_params.threadId,
    threadSettings = {
      approvalPolicy = held_restore_params.approvalPolicy,
      approvalsReviewer = held_restore_params.approvalsReviewer,
      sandboxPolicy = held_restore_params.sandboxPolicy,
      activePermissionProfile = vim.NIL,
    },
  })
  truthy(vim.wait(1000, function()
    return seal._state.jobs[1] and seal._state.jobs[1].turn_id == "main-turn"
  end, 5), "restore release should retry instead of reviving stale busy state")
  complete_declaration("function retried_after_external_completion() end")
  seal.reject(1)
end

function tests.prompt_keeps_originating_snapshot()
  setup({ "original" })
  local deliver
  seal.setup({
    client = fake,
    save_before_agent = false,
    root = function()
      return test_root
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    input = function(_, callback)
      deliver = callback
    end,
    keymaps = { prompt = false, chat = false },
  })
  seal.prompt()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited while prompting" })
  deliver("explain")
  truthy(request(fake, "turn/start") == nil, "changed origin buffer should prevent submission")
end

function tests.review_defaults_null_kinds_and_cleans_up_after_open_failure()
  local Review = require("seal.review")
  local lines = Review.lines({ {
    path = test_root .. "/example.lua",
    kind = vim.NIL,
    diff = "@@ -1 +1 @@\n-old\n+new",
  } }, test_root)
  truthy(lines[1]:find("UPDATE example.lua", 1, true) ~= nil,
    "a protocol null kind should render as an update")
  equal(Review.lines(vim.NIL, test_root), { "<no proposed changes were provided>" },
    "a null changes collection should render a safe placeholder")
  local null_entry_lines = Review.lines({ vim.NIL }, test_root)
  truthy(null_entry_lines[1]:find("INVALID", 1, true) ~= nil,
    "a null change entry should render without raising")

  local original_open_win = vim.api.nvim_open_win
  local original_delete = vim.api.nvim_buf_delete
  vim.api.nvim_open_win = function()
    error("forced review window failure")
  end
  vim.api.nvim_buf_delete = function()
    error("simulated E11 in the command-line window")
  end
  local ok = pcall(Review.open, {
    id = "failed-open",
    root = test_root,
    changes = {},
    can_accept = false,
    on_decision = function() end,
    on_defer = function() end,
  })
  vim.api.nvim_open_win = original_open_win
  vim.api.nvim_buf_delete = original_delete
  truthy(not ok, "the injected window failure should propagate")
  equal(vim.fn.bufnr("seal://review/failed-open"), -1,
    "a failed review window must not leave a named scratch buffer behind")

  local decision
  Review.open({
    id = "cancel-key",
    root = test_root,
    changes = {},
    can_accept = true,
    on_decision = function(value)
      decision = value
    end,
    on_defer = function() end,
  })
  truthy(vim.fn.maparg("a", "n", false, true).callback == nil,
    "ordinary editing keys must not decide a patch")
  truthy(vim.fn.maparg("d", "n", false, true).callback == nil,
    "ordinary editing keys must not reject a patch")
  vim.fn.maparg("x", "n", false, true).callback()
  equal(decision, "cancel", "x should reject the patch and stop its turn")

  setup({ "" })
  seal.submit("review invalid patch data")
  for index, invalid_changes in ipairs({ vim.NIL, { vim.NIL } }) do
    local item_id = "invalid-changes-" .. index
    local request_id = 180 + index
    seal._notification("item/started", {
      threadId = "main-thread",
      turnId = "main-turn",
      item = {
        id = item_id,
        type = "fileChange",
        status = "inProgress",
        changes = invalid_changes,
      },
    })
    local handled, handler_error = pcall(seal._server_request, {
      id = request_id,
      method = "item/fileChange/requestApproval",
      params = { threadId = "main-thread", turnId = "main-turn", itemId = item_id },
    })
    truthy(handled, "protocol null changes must not escape the request handler: " .. tostring(handler_error))
    truthy(seal._state.reviews[tostring(request_id)].warning ~= nil,
      "invalid change data should produce a non-acceptable review")
    vim.fn.maparg("<Esc>", "n", false, true).callback()
  end
end

local order = {
  "routes_only_known_prefixes",
  "normalizes_nested_indentation",
  "large_context_keeps_cursor_line",
  "visual_selection_shares_the_context_budget",
  "visual_prompt_mapping_uses_the_active_selection",
  "repeated_setup_removes_only_its_old_global_keymaps",
  "repeated_setup_removes_leader_keymaps_after_termcode_expansion",
  "freeform_uses_main_thread_unchanged",
  "routine_turn_notifications_require_verbose_mode",
  "patch_adds_minimal_change_guidance_to_the_main_thread",
  "removed_agent_prefixes_are_plain_prompts",
  "bounded_policy_restore_accepts_app_server_workspace_defaults",
  "freeform_queues_behind_an_active_turn",
  "early_completion_waits_for_start_ownership_before_pumping",
  "freeform_uses_the_post_format_buffer_and_selection",
  "freeform_maps_context_through_a_full_buffer_format",
  "freeform_keeps_a_selection_expanded_by_formatting",
  "preflight_reloads_an_external_edit_before_capture",
  "preflight_preserves_local_changes_on_external_conflict",
  "command_does_not_retry_a_failed_preflight",
  "preflight_blocks_an_externally_deleted_file",
  "preflight_blocks_deleted_file_with_local_changes",
  "preflight_compares_disk_using_the_buffer_encoding",
  "preflight_compares_utf16_disk_content",
  "post_write_buffer_mutation_blocks_freeform_turn",
  "post_write_other_buffer_mutation_blocks_freeform_turn",
  "post_write_buffer_wipe_aborts_without_an_error",
  "disk_only_formatter_blocks_without_dropping_a_declaration",
  "completed_attached_tui_turn_reloads_external_edits",
  "completed_turn_does_not_check_unrelated_projects",
  "completed_turn_preserves_a_modified_external_conflict",
  "freeform_refuses_other_modified_project_buffers",
  "chat_reads_and_renders_the_backing_thread",
  "attach_before_a_prompt_lets_the_side_tui_create_the_shared_thread",
  "attach_resumes_a_thread_after_its_first_turn_materializes",
  "attach_keeps_the_empty_fallback_subscribed_until_adoption",
  "wiped_chat_ignores_a_delayed_refresh",
  "declaration_queues_during_active_main_turn",
  "declaration_uses_shared_read_only_turn",
  "interface_prefix_requests_api_without_implementation",
  "first_declaration_starts_the_shared_thread",
  "thread_setting_changes_stay_on_the_shared_thread",
  "declaration_restores_main_thread_settings",
  "declaration_turn_declines_file_changes",
  "declaration_retries_after_a_tui_turn_wins_the_start_race",
  "stale_status_read_does_not_block_the_queue",
  "failed_settings_restore_blocks_the_next_turn",
  "rejected_declaration_start_does_not_wait_for_a_noop_restore",
  "stale_restore_marker_cannot_drop_a_new_lease_obligation",
  "server_request_is_resolved_without_an_interactive_client",
  "multi_file_patch_waits_for_review_and_acceptance",
  "accepted_patch_reloads_its_open_buffer_when_the_item_completes",
  "client_exit_rechecks_buffers_for_accepted_patches_without_completion_events",
  "accepted_delete_does_not_latch_a_conflict_on_its_unmodified_source_buffer",
  "failed_patch_application_is_reported_and_cleared",
  "failed_bounded_patch_application_stops_and_fails_the_turn",
  "accepted_patch_preserves_edits_made_while_codex_applies_it",
  "rejecting_a_bounded_patch_stops_its_turn",
  "cancel_key_rejects_and_stops_a_bounded_patch_end_to_end",
  "patch_patch_stops_only_after_the_accepted_patch_is_applied",
  "second_bounded_patch_is_rejected_and_invalidates_the_first_review",
  "bounded_v2_child_patch_inherits_review_and_stops_the_root_turn",
  "bounded_turn_that_finishes_without_a_patch_fails",
  "numeric_work_ids_do_not_fall_through_to_legacy_kind_indexes",
  "prompting_from_patch_review_targets_the_source_buffer",
  "unloaded_named_buffers_do_not_block_patch_review",
  "unloading_a_target_during_review_does_not_permanently_block_acceptance",
  "modified_review_target_is_saved_before_acceptance",
  "external_review_target_change_remains_blocked",
  "unsafe_patch_has_no_accept_mapping",
  "command_approvals_require_an_explicit_decision_by_default",
  "command_approvals_auto_accept_when_explicitly_enabled",
  "command_escalations_require_explicit_approval_even_when_commands_auto_accept",
  "custom_bounded_prefix_declines_commands_that_require_approval",
  "command_approval_warns_about_unpreviewed_writes",
  "command_approval_honors_available_decisions",
  "dismissed_command_uses_the_advertised_cancel",
  "external_resolution_surfaces_the_next_patch_review",
  "seal_prompt_waits_for_a_tui_owned_turn",
  "seal_owned_child_thread_can_request_patch_review",
  "unobserved_child_approval_fails_closed",
  "unobserved_child_request_never_opens_a_review",
  "tui_owned_child_thread_is_not_claimed_by_seal",
  "declarations_run_fifo_on_the_shared_thread",
  "failed_interrupt_keeps_cancelled_turn_requests_fail_closed",
  "cancel_before_turn_start_response_waits_for_confirmed_ownership",
  "turn_started_notification_waits_for_start_response_ownership",
  "thread_failure_clears_a_stale_settings_restore_block",
  "failed_agent_turn_reports_the_server_error",
  "closed_shared_thread_clears_its_jobs",
  "collocated_jobs_are_preserved_and_selected_newest_first",
  "spinner_renders_before_app_server_is_ready",
  "insert_leave_noop_formatter_keeps_the_startup_spinner",
  "agent_prompts_render_before_backend_is_ready",
  "concurrent_initial_prompts_run_fifo",
  "session_read_failure_clears_immediate_agent_spinner",
  "app_server_start_failure_clears_immediate_spinners",
  "delayed_old_client_exit_preserves_restarted_activity",
  "status_batch_preserves_submission_order",
  "spinner_is_anchored_and_animates_in_place",
  "mapping_away_from_marker_preserves_global_behavior",
  "escape_at_agent_markers_cancels_normal_and_patch_turns",
  "rejecting_one_queued_job_keeps_its_sibling",
  "multiple_jobs_share_and_restore_buffer_mappings",
  "closed_source_buffer_discards_ready_jobs_and_mappings",
  "mapping_installed_during_a_job_is_not_clobbered",
  "mapping_restoration_preserves_replace_keycodes",
  "buffer_edit_reanchors_all_jobs",
  "deleting_every_line_keeps_buffer_reconciliation_usable",
  "deleting_a_prefix_that_leaves_a_real_blank_line_does_not_fake_an_empty_buffer",
  "deleting_marked_line_keeps_and_reanchors_job",
  "insert_mode_away_from_marker_keeps_and_reanchors_job",
  "undo_away_from_marker_keeps_job",
  "editing_selected_context_keeps_job",
  "new_thread_interrupts_and_detaches_old_thread",
  "new_thread_serializes_with_an_inflight_session_start",
  "prompt_waits_for_the_replacement_thread_started_by_seal_new",
  "early_result_replays_after_late_start_response",
  "queued_jobs_dispatch_in_their_own_buffers",
  "failed_freeform_preflight_keeps_other_buffer_preview",
  "sequential_results_can_be_accepted_independently",
  "accepted_multiline_preview_moves_collocated_siblings_after_it",
  "collocated_acceptance_preserves_a_siblings_existing_ambiguity",
  "acceptance_finalizes_when_sibling_reconciliation_fails",
  "preview_accepts_as_one_edit",
  "automatic_declarations_preserve_edits_and_separate_undo_steps",
  "automatic_declarations_apply_without_switching_back_to_the_source",
  "automatic_declarations_rebase_collocated_queued_results",
  "automatic_declarations_leave_conflicts_for_resolution",
  "reject_leaves_buffer_untouched",
  "freeform_preserves_an_existing_preview",
  "patch_preserves_queued_declaration_spinners",
  "patch_patch_reload_preserves_unaffected_previews",
  "attached_tui_turn_preserves_an_existing_preview",
  "external_file_change_blocks_preview_acceptance",
  "external_file_change_retains_a_blocked_preview",
  "identical_writes_do_not_invalidate_a_preview",
  "buffer_rename_blocks_preview_rendering",
  "buffer_rename_blocks_preview_acceptance",
  "completion_text_change_keeps_generation",
  "result_follows_local_edits",
  "python_type_alias_reaches_preview_by_default",
  "multiple_declarations_are_rejected",
  "wrong_declaration_kind_is_rejected",
  "wrapper_with_multiple_functions_is_rejected",
  "javascript_arrow_function_is_accepted",
  "interface_equivalents_are_accepted",
  "failed_editor_apply_keeps_the_canonical_preview",
  "ready_preview_reindents_from_raw_output_after_an_edit",
  "same_line_markers_dispatch_by_column",
  "collocated_ready_and_blocked_jobs_remain_actionable",
  "deleted_final_line_reanchors_to_the_eof_boundary",
  "global_mapping_changes_are_resolved_at_dispatch_time",
  "pending_limit_bounds_retained_context",
  "blocked_agent_retries_in_fifo_order_after_save",
  "one_hundred_marks_share_one_fast_buffer_model",
  "reconcile_failure_blocks_acceptance_until_a_clean_reload",
  "delayed_settings_restore_cannot_mutate_a_reset_scheduler",
  "cancelled_running_item_retires_until_its_lease_finishes",
  "early_server_request_replays_only_after_turn_confirmation",
  "nonretryable_start_failure_discards_buffered_turn_events",
  "resolved_request_deduplication_is_bounded",
  "buffered_collab_ownership_replays_an_exact_child_request",
  "cancelled_start_never_replays_an_early_server_request",
  "external_settings_before_start_response_become_restore_target",
  "inflight_restore_converges_on_the_latest_external_settings",
  "settings_restore_clears_a_stale_permission_profile",
  "external_completion_during_restore_does_not_revive_busy_state",
  "prompt_keeps_originating_snapshot",
  "review_defaults_null_kinds_and_cleans_up_after_open_failure",
}

for _, name in ipairs(order) do
  tests[name]()
  io.stdout:write("ok - " .. name .. "\n")
end

seal._reset()
vim.fn.delete(test_root, "rf")
vim.fn.delete(second_root, "rf")
vim.fn.delete(other_root, "rf")
io.stdout:write(string.format("%d tests passed\n", #order))
