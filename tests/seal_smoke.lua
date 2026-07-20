local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local seal = require("seal")
local errors = {}
seal.setup({
  bridge = root .. "/bin/seal-bridge",
  root = function()
    return root
  end,
  notify = function(message, level)
    if level == vim.log.levels.ERROR or level == vim.log.levels.WARN then
      table.insert(errors, message)
    end
  end,
  keymaps = { prompt = false, chat = false },
})

vim.cmd("enew!")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "", "" })

local ok, smoke_error = xpcall(function()
  assert(seal.submit("fun: define seal_smoke_one with no arguments and return true"))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(seal.submit("fun: define seal_smoke_two with no arguments and return true"))
  local started = vim.wait(10000, function()
    local current = seal.status()
    return current.generating_count + current.preview_count == 2 or #errors > 0
  end, 10)
  assert(started and #errors == 0, "declaration jobs did not start: " .. table.concat(errors, "; "))
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- edit while both queued jobs run" })
  local ready = vim.wait(120000, function()
    return seal.status().preview_count == 2 or #errors > 0
  end, 20)
  assert(ready, "timed out waiting for queued Seal declarations: " .. vim.inspect(seal.status()))
  assert(#errors == 0, table.concat(errors, "; "))
  assert(seal.status().preview_count == 2, "Seal completed without both inline previews")
  local history
  local history_error
  seal._state.client:request("thread/read", {
    threadId = seal.status().thread_id,
    includeTurns = true,
  }, function(result, err)
    history = result and result.thread
    history_error = err
  end)
  assert(vim.wait(5000, function()
    return history ~= nil or history_error ~= nil
  end, 20), "timed out reading the shared Seal conversation")
  assert(not history_error, vim.inspect(history_error))
  assert(#history.turns >= 2, "declaration turns were not retained in the shared Seal conversation")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  assert(seal.accept(), "could not accept the second Seal preview")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(seal.accept(), "could not accept the first Seal preview")
  local source = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(source:find("queued jobs", 1, true), "accepted declarations overwrote the intervening edit")
  assert(source:find("seal_smoke_one", 1, true), "accepted declaration did not contain seal_smoke_one")
  assert(source:find("seal_smoke_two", 1, true), "accepted declaration did not contain seal_smoke_two")
end, debug.traceback)

local status = seal.status()
if status.thread_id and seal._state.client then
  local deleted = false
  seal._state.client:request("thread/delete", { threadId = status.thread_id }, function()
    deleted = true
  end)
  vim.wait(5000, function()
    return deleted
  end, 20)
end
seal.stop()

if not ok then
  error(smoke_error)
end
io.stdout:write("real queued Seal declaration smoke test passed\n")
