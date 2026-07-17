local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local Client = require("seal.client")
local completed
local answer
local protocol_error

local client = Client.new({
  bridge = root .. "/bin/seal-bridge",
  on_notification = function(method, params)
    if method == "item/completed" and params.item and params.item.type == "agentMessage" then
      answer = params.item.text
    elseif method == "turn/completed" then
      completed = params.turn
    elseif method == "error" then
      protocol_error = params.error and params.error.message or "unknown app-server error"
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
local ok, smoke_error = xpcall(function()
  source = request("thread/start", {
    cwd = root,
    sandbox = "read-only",
    approvalPolicy = "never",
  }).thread

  local turn = request("turn/start", {
    threadId = source.id,
    clientUserMessageId = "seal-smoke",
    sandboxPolicy = { type = "workspaceWrite", writableRoots = {}, networkAccess = false },
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

  local fork = request("thread/fork", {
    threadId = source.id,
    cwd = root,
    ephemeral = true,
    sandbox = "read-only",
    approvalPolicy = "never",
    developerInstructions = "Return exactly one requested declaration. Do not modify files or use Markdown fences.",
    excludeTurns = true,
  }).thread
  assert(fork.ephemeral == true, "fork was not ephemeral")
  assert(fork.forkedFromId == source.id, "fork did not copy the source thread")
  request("thread/unsubscribe", { threadId = fork.id })
end, debug.traceback)

if source then
  pcall(request, "thread/delete", { threadId = source.id })
end
client:stop()

if not ok then
  error(smoke_error)
end
io.stdout:write("real app-server smoke test passed\n")
