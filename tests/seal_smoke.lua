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
    if level == vim.log.levels.ERROR then
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
  local ready = vim.wait(120000, function()
    return seal.status().preview_count == 2 or #errors > 0
  end, 20)
  assert(ready, "timed out waiting for parallel Seal declarations")
  assert(#errors == 0, table.concat(errors, "; "))
  assert(seal.status().preview_count == 2, "Seal completed without both inline previews")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(seal.accept(), "could not accept the second Seal preview")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert(seal.accept(), "could not accept the first Seal preview")
  local source = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
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
io.stdout:write("real parallel Seal declaration smoke test passed\n")
