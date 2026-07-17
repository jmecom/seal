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
  terminal = function()
    error("declaration generation should not open the terminal")
  end,
  notify = function(message, level)
    if level == vim.log.levels.ERROR then
      table.insert(errors, message)
    end
  end,
  keymaps = { prompt = false, terminal = false },
})

vim.cmd("enew!")
vim.bo.filetype = "lua"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })

local ok, smoke_error = xpcall(function()
  assert(seal.submit("fun: define seal_smoke with no arguments and return true"))
  local ready = vim.wait(120000, function()
    return seal._state.preview ~= nil or #errors > 0
  end, 20)
  assert(ready, "timed out waiting for Seal declaration")
  assert(#errors == 0, table.concat(errors, "; "))
  assert(seal._state.preview, "Seal completed without an inline preview")
  assert(seal.accept(), "could not accept the Seal preview")
  local source = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(source:find("seal_smoke", 1, true), "accepted declaration did not contain seal_smoke")
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
io.stdout:write("real Seal declaration smoke test passed\n")
