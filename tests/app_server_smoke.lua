local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local Backend = require("seal.backend")
local backend_config = { backend = vim.env.SEAL_BACKEND or "codex", acp = {} }
local completed
local answer
local protocol_error
local file_items = {}
local patch_approval_seen = false
local review_file

local function item_key(params, item_id)
  return table.concat({ tostring(params.threadId), tostring(params.turnId), tostring(item_id) }, "\0")
end

local client
client = Backend.new(backend_config, {
  bridge = root .. "/bin/seal-bridge",
  on_notification = function(method, params)
    if method == "item/started" and params.item and params.item.type == "fileChange" then
      file_items[item_key(params, params.item.id)] = params.item
    elseif method == "item/completed" and params.item and params.item.type == "agentMessage" then
      answer = params.item.text
    elseif method == "turn/completed" then
      completed = params.turn
    elseif method == "error" then
      protocol_error = params.error and params.error.message or "unknown app-server error"
    end
  end,
  on_server_request = function(request_message)
    local params = request_message.params or {}
    if request_message.method == "item/fileChange/requestApproval" then
      local item = file_items[item_key(params, params.itemId)]
      if not item or type(item.changes) ~= "table" or #item.changes == 0 then
        protocol_error = "file approval arrived without its proposed changes"
        client:respond(request_message.id, { decision = "cancel" })
        return
      end
      if review_file and (vim.uv or vim.loop).fs_stat(review_file) then
        protocol_error = "the reviewed file existed before patch approval"
        client:respond(request_message.id, { decision = "cancel" })
        return
      end
      local expected_change = false
      for _, change in ipairs(item.changes) do
        expected_change = expected_change
          or (type(change.path) == "string"
            and vim.fs.basename(change.path) == "seal-review-smoke.txt"
            and type(change.diff) == "string"
            and change.diff:find("approved after review", 1, true) ~= nil)
      end
      if not expected_change then
        protocol_error = "the proposed patch did not contain the expected reviewed file"
        client:respond(request_message.id, { decision = "cancel" })
        return
      end
      patch_approval_seen = true
      client:respond(request_message.id, { decision = "accept" })
    elseif request_message.method == "item/commandExecution/requestApproval" then
      client:respond(request_message.id, { decision = "decline" })
    elseif request_message.method == "item/permissions/requestApproval" then
      client:respond(request_message.id, { permissions = {}, scope = "turn" })
    else
      client:respond_error(request_message.id, -32601, "unsupported smoke-test request")
    end
  end,
  on_error = function(message)
    protocol_error = message
  end,
})

local function wait_for(description, predicate, timeout)
  if not vim.wait(timeout or 30000, predicate, 20) then
    error(string.format("timed out waiting for %s%s", description, protocol_error and ": " .. protocol_error or ""))
  end
end

local function request(method, params, timeout)
  local done = false
  local result
  local request_error
  client:request(method, params, function(value, err)
    result = value
    request_error = err
    done = true
  end)
  wait_for(method, function()
    return done
  end, timeout)
  if request_error then
    error(string.format("%s failed: %s", method, request_error.message or vim.inspect(request_error)))
  end
  return result
end

local started = false
local start_error
client:start(function(ok, err)
  started = ok
  start_error = err
end)
wait_for("app-server initialization", function()
  return started or start_error ~= nil
end)
if not started then
  error(start_error)
end

local source
local patch_source
local review_root
local ok, smoke_error = xpcall(function()
  source = request("thread/start", {
    cwd = root,
    sandbox = "read-only",
    approvalPolicy = "never",
  }).thread

  local turn = request("turn/start", {
    threadId = source.id,
    clientUserMessageId = "seal-smoke",
    sandboxPolicy = { type = "readOnly", networkAccess = false },
    approvalPolicy = "never",
    input = {
      { type = "text", text = "Write a Lua function named seal_smoke that returns true. Do not call tools." },
    },
    additionalContext = {
      ["seal.smoke"] = { kind = "untrusted", value = "The target language is Lua." },
    },
    outputSchema = {
      type = "object",
      properties = { code = { type = "string" } },
      required = { "code" },
      additionalProperties = false,
    },
  }).turn

  wait_for("structured Codex turn", function()
    return completed and completed.id == turn.id
  end, 120000)
  assert(completed.status == "completed", "turn status was " .. tostring(completed.status))
  assert(answer, "turn completed without an agent message")
  local decoded = vim.json.decode(answer)
  assert(type(decoded.code) == "string" and decoded.code:find("seal_smoke", 1, true), "invalid structured code")

  local history = request("thread/read", { threadId = source.id, includeTurns = true }).thread
  assert(#history.turns > 0, "thread/read did not return the completed turn")
  local saw_user = false
  local saw_agent = false
  for _, history_turn in ipairs(history.turns) do
    for _, item in ipairs(history_turn.items) do
      saw_user = saw_user or item.type == "userMessage"
      saw_agent = saw_agent or item.type == "agentMessage"
    end
  end
  assert(saw_user and saw_agent, "thread/read did not return the user and agent messages")

  completed = nil
  answer = nil
  local second_turn = request("turn/start", {
    threadId = source.id,
    clientUserMessageId = "seal-smoke-follow-up",
    sandboxPolicy = { type = "readOnly", networkAccess = false },
    approvalPolicy = "never",
    input = {
      { type = "text", text = "Return a second Lua function named seal_smoke_follow_up that returns true. Do not call tools." },
    },
    outputSchema = {
      type = "object",
      properties = { code = { type = "string" } },
      required = { "code" },
      additionalProperties = false,
    },
  }).turn
  wait_for("second structured Codex turn", function()
    return completed and completed.id == second_turn.id
  end, 120000)
  assert(completed.status == "completed", "second turn status was " .. tostring(completed.status))
  local second = vim.json.decode(answer)
  assert(
    type(second.code) == "string" and second.code:find("seal_smoke_follow_up", 1, true),
    "invalid second structured code"
  )

  history = request("thread/read", { threadId = source.id, includeTurns = true }).thread
  assert(#history.turns >= 2, "the shared thread did not retain both structured turns")

  review_root = vim.fn.tempname()
  assert(vim.fn.mkdir(review_root, "p") == 1, "could not create the patch-review smoke directory")
  review_file = review_root .. "/seal-review-smoke.txt"
  patch_source = request("thread/start", {
    cwd = review_root,
    sandbox = "read-only",
    approvalPolicy = "untrusted",
    approvalsReviewer = "user",
  }).thread
  completed = nil
  answer = nil
  local patch_turn = request("turn/start", {
    threadId = patch_source.id,
    clientUserMessageId = "seal-review-smoke",
    sandboxPolicy = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
    approvalPolicy = "untrusted",
    approvalsReviewer = "user",
    input = {
      {
        type = "text",
        text = table.concat({
          backend_config.backend == "acp"
            and "Use your file editing tool to add seal-review-smoke.txt in the current directory."
            or "Use the apply_patch tool to add seal-review-smoke.txt in the current directory.",
          "Its complete contents must be exactly: approved after review",
          "Do not use shell commands or any other write mechanism. Do not make other changes.",
        }, " "),
      },
    },
  }).turn

  wait_for("reviewed Codex patch", function()
    return (completed and completed.id == patch_turn.id) or protocol_error ~= nil
  end, 120000)
  assert(not protocol_error, protocol_error)
  assert(completed.status == "completed", "patch turn status was " .. tostring(completed.status))
  assert(patch_approval_seen, "Codex changed the file without a file-change approval")
  assert(vim.deep_equal(vim.fn.readfile(review_file), { "approved after review" }), "approved patch contents differed")
end, debug.traceback)

if source and backend_config.backend == "codex" then
  pcall(request, "thread/delete", { threadId = source.id })
end
if patch_source and backend_config.backend == "codex" then
  pcall(request, "thread/delete", { threadId = patch_source.id })
end
client:stop()
if review_root then
  vim.fn.delete(review_root, "rf")
end

if not ok then
  error(smoke_error)
end
io.stdout:write("real " .. Backend.name(backend_config) .. " session and patch approval smoke test passed\n")
