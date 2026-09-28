-- One-way handoff to Alto. This connection does not own an agent session or
-- participate in Seal's inline preview and file review lifecycle.
local M = {}
local connections = {}
local uv = vim.uv or vim.loop

function M.request(payload, opts, callback)
  opts = opts or {}
  local socket_path = opts.socket or vim.fn.expand("~/.cache/alto/seal.sock")
  local pipe = uv.new_pipe(false)
  local timer = uv.new_timer()
  local done = false
  local data = ""
  local wrote = false
  local function finish(result, err)
    if done then return end
    done = true
    connections[pipe] = nil
    if not timer:is_closing() then timer:stop(); timer:close() end
    if not pipe:is_closing() then pipe:read_stop(); pipe:close() end
    vim.schedule(function() callback(result, err) end)
  end
  connections[pipe] = function()
    finish(nil, wrote and "Seal stopped; check Alto before retrying the handoff" or "Seal stopped")
  end
  local message = vim.tbl_extend("force", payload, { version = 1 })
  local encoded, wire = pcall(vim.json.encode, message)
  if not encoded then
    finish(nil, "Could not encode the Alto handoff: " .. tostring(wire))
    return
  end
  if #wire > 1024 * 1024 then
    finish(nil, "The Alto handoff is too large")
    return
  end
  timer:start(opts.timeout_ms or 20000, 0, function()
    finish(nil, "Alto did not confirm delivery; check the chat and queue before retrying")
  end)
  pipe:connect(socket_path, function(connect_error)
    if done then return end
    if connect_error then
      finish(nil, "Could not connect to Alto's Seal plugin at " .. socket_path .. ": " .. connect_error)
      return
    end
    pipe:read_start(function(read_error, chunk)
      if done then return end
      if read_error then finish(nil, "Could not read Alto's reply: " .. read_error); return end
      if not chunk then finish(nil, "Alto closed the connection; check the chat before retrying"); return end
      data = data .. chunk
      if #data > 1024 * 1024 then finish(nil, "Alto reply is too large"); return end
      local ending = data:find("\n", 1, true)
      if not ending then return end
      local ok, result = pcall(vim.json.decode, data:sub(1, ending - 1))
      if not ok or type(result) ~= "table" then
        finish(nil, "Invalid response from Alto")
      elseif result.ok ~= true then
        finish(nil, result.error or "Alto rejected the handoff")
      else
        finish(result)
      end
    end)
    wrote = true
    pipe:write(wire .. "\n", function(write_error)
      if write_error then finish(nil, "Could not send to Alto: " .. write_error) end
    end)
  end)
end

function M.stop()
  local pending = {}
  for _, cancel in pairs(connections) do table.insert(pending, cancel) end
  for _, cancel in ipairs(pending) do cancel() end
end

return M
