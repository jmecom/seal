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
      callback({
        thread = {
          id = params.threadId,
          cwd = "/tmp/seal-project",
          status = self.thread_status or { type = "idle" },
          turns = params.includeTurns and (self.thread_turns or {}) or {},
        },
      })
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
local fake
local copied
local buffer_sequence = 0

local function setup(lines, overrides)
  seal._reset()
  notifications = {}
  copied = nil
  fake = fake_client()
  local options = {
    client = fake,
    save_before_agent = false,
    root = function()
      return "/tmp/seal-project"
    end,
    notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end,
    keymaps = { prompt = false, chat = false },
  }
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
  equal(turn.params.approvalPolicy, "never", "background turns must not wait for an unavailable approval UI")
  equal(turn.params.sandboxPolicy, {
    type = "workspaceWrite",
    writableRoots = {},
    networkAccess = false,
  }, "normal turns should use a protocol-valid workspace-writing policy")
  equal(request(fake, "thread/start").params.approvalPolicy, "never", "the main thread should be non-interactive")
  equal(request(fake, "thread/start").params.sandbox, "workspace-write", "the main thread should be workspace-writing")
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
  vim.api.nvim_buf_set_name(other, "/tmp/seal-project/post-write-other.lua")
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
      return path:find("seal%-other%-project") and "/tmp/seal-other-project" or "/tmp/seal-project"
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
  vim.api.nvim_buf_set_name(other, "/tmp/seal-project/other-unsaved.lua")
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
  seal.submit("follow up from chat")
  local follow_up = request(fake, "turn/start", 2)
  equal(follow_up.params.threadId, "main-thread", "prompting from chat should reuse its backing thread")
  truthy(follow_up.params.additionalContext["seal.editor"].value:find("example-", 1, true), "chat prompts should retain the source buffer context")
  vim.fn.maparg("q", "n", false, true).callback()
  equal(vim.api.nvim_get_current_buf(), source, "closing chat should return to the source buffer")
end

function tests.attach_copies_the_real_tui_command()
  setup({ "" }, {
    copy = function(value)
      copied = value
    end,
  })
  seal.attach()
  truthy(copied:find("codex", 1, true), "attach command should invoke Codex")
  truthy(copied:find("resume", 1, true), "attach command should resume the live thread")
  truthy(copied:find("--remote", 1, true), "attach command should use the app-server transport")
  truthy(copied:find("ws://127.0.0.1:4567", 1, true), "attach command should use Seal's live endpoint")
  truthy(copied:find("main-thread", 1, true), "attach command should target the backing chat thread")
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
      cwd = "/tmp/seal-project",
      status = { type = "idle" },
      turns = {},
    },
  })
  truthy(seal._state.chat == nil, "a delayed refresh must not reopen a wiped chat")
  equal(vim.api.nvim_get_current_buf(), source, "a delayed refresh must not steal focus")
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
  truthy(notifications[#notifications].message:find(":SealChat", 1, true), "busy declaration should point to the chat")
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

function tests.server_request_is_resolved_without_an_interactive_client()
  setup({ "" })
  seal._state.live["/tmp/project-a"] = { root = "/tmp/project-a", thread_id = "thread-a" }
  seal._state.owned_turns["seal-turn"] = true
  seal._server_request({
    id = 41,
    method = "item/commandExecution/requestApproval",
    params = { threadId = "thread-a", turnId = "seal-turn" },
  })
  equal(fake.responses[#fake.responses], {
    id = 41,
    result = { decision = "decline" },
  }, "approval should be declined instead of hanging")
  truthy(notifications[#notifications].message:find("declined", 1, true), "the declined interaction should be visible")

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

function tests.freeform_clears_an_existing_preview()
  setup({ "" })
  seal.submit("fun: focused change")
  complete_declaration("function focused_change() end")
  truthy(seal._state.preview ~= nil, "declaration preview should exist before the freeform prompt")
  seal.submit("make a broader change")
  truthy(seal._state.preview == nil, "a workspace-writing turn must clear the pending preview")
end

function tests.attached_tui_turn_clears_an_existing_preview()
  setup({ "" })
  seal.submit("fun: focused change")
  complete_declaration("function focused_change() end")
  seal._notification("turn/started", {
    threadId = "main-thread",
    turn = { id = "tui-turn", status = "inProgress" },
  })
  truthy(seal._state.preview == nil, "a TUI-started workspace turn must clear the pending preview")
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
  truthy(seal._state.preview == nil, "the externally stale preview should be cleared")
  vim.fn.delete(path)
end

function tests.external_file_change_blocks_preview_rendering()
  setup({ "" })
  local path = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(0, path)
  vim.cmd("silent write")
  seal.submit("fun: stale before preview")
  vim.fn.writefile({ "local changed_externally = true" }, path)
  complete_declaration("function stale_before_preview() end")
  truthy(seal._state.preview == nil, "an externally stale result must not be rendered")
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
  vim.api.nvim_buf_set_name(0, "/tmp/seal-project/renamed-before-preview.lua")
  complete_declaration("function stale_after_rename() end")
  truthy(seal._state.preview == nil, "a result for the old buffer path must not be rendered")
end

function tests.buffer_rename_blocks_preview_acceptance()
  setup({ "" })
  seal.submit("fun: stale after rename")
  complete_declaration("function stale_after_rename() end")
  vim.api.nvim_buf_set_name(0, "/tmp/seal-project/renamed-after-preview.lua")
  truthy(not seal.accept(), "a preview for the old buffer path must not be accepted")
  truthy(seal._state.preview == nil, "the renamed preview should be cleared")
end

function tests.completion_text_change_cancels_generation()
  setup({ "" })
  seal.submit("fun: cancelled by completion")
  vim.api.nvim_exec_autocmds("TextChangedP", { buffer = 0 })
  truthy(seal._state.generation == nil, "completion-menu edits should cancel declaration generation")
  equal(request(fake, "turn/interrupt").params.turnId, "fork-turn", "the cancelled fork turn should be interrupted")
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

local order = {
  "routes_only_known_prefixes",
  "normalizes_nested_indentation",
  "large_context_keeps_cursor_line",
  "visual_selection_shares_the_context_budget",
  "freeform_uses_main_thread_unchanged",
  "freeform_steers_an_active_turn",
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
  "completed_attached_tui_turn_reloads_external_edits",
  "completed_turn_does_not_check_unrelated_projects",
  "completed_turn_preserves_a_modified_external_conflict",
  "freeform_refuses_other_modified_project_buffers",
  "chat_reads_and_renders_the_backing_thread",
  "attach_copies_the_real_tui_command",
  "wiped_chat_ignores_a_delayed_refresh",
  "declaration_waits_for_active_main_turn",
  "declaration_uses_safe_ephemeral_fork",
  "first_declaration_handles_empty_main_thread",
  "thread_setting_changes_flow_into_forks",
  "null_thread_settings_are_omitted_from_forks",
  "server_request_is_resolved_without_an_interactive_client",
  "superseded_fork_is_unsubscribed",
  "new_thread_interrupts_and_detaches_old_thread",
  "preview_accepts_as_one_edit",
  "reject_leaves_buffer_untouched",
  "freeform_clears_an_existing_preview",
  "attached_tui_turn_clears_an_existing_preview",
  "external_file_change_blocks_preview_acceptance",
  "external_file_change_blocks_preview_rendering",
  "identical_writes_do_not_invalidate_a_preview",
  "buffer_rename_blocks_preview_rendering",
  "buffer_rename_blocks_preview_acceptance",
  "completion_text_change_cancels_generation",
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
