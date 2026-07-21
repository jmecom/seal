local M = {}

local function change_kind(change)
  if type(change.kind) == "table" then
    return type(change.kind.type) == "string" and change.kind.type or "update"
  end
  return type(change.kind) == "string" and change.kind or "update"
end

local function move_path(change)
  if type(change.kind) ~= "table" then
    return nil
  end
  local path = change.kind.movePath or change.kind.move_path
  return path == vim.NIL and nil or path
end

local function display_path(root, path)
  if type(path) ~= "string" or path == "" then
    return "<unknown path>"
  end
  local normalized = vim.fs.normalize(path)
  local normalized_root = vim.fs.normalize(root)
  local prefix = normalized_root .. "/"
  if normalized:sub(1, #prefix) == prefix then
    return normalized:sub(#prefix + 1)
  end
  return path
end

function M.lines(changes, root, warning)
  local lines = {}
  if warning then
    vim.list_extend(lines, { "REVIEW BLOCKED: " .. warning, "" })
  end
  for index, change in ipairs(changes or {}) do
    local path = display_path(root, change.path)
    local kind = change_kind(change)
    local destination = move_path(change)
    local label = string.format("%s %s", kind:upper(), path)
    if destination then
      label = label .. " -> " .. display_path(root, destination)
    end
    if index > 1 then
      table.insert(lines, "")
    end
    table.insert(lines, label)
    table.insert(lines, string.rep("=", math.max(3, vim.fn.strdisplaywidth(label))))
    local diff = type(change.diff) == "string" and change.diff or ""
    if diff == "" then
      table.insert(lines, "<diff unavailable>")
    else
      vim.list_extend(lines, vim.split(diff, "\n", { plain = true, trimempty = false }))
    end
  end
  if #lines == 0 then
    return { "<no proposed changes were provided>" }
  end
  return lines
end

local function dimensions(lines)
  local max_width = 40
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end
  local screen_width = math.max(20, vim.o.columns - 4)
  local screen_height = math.max(4, vim.o.lines - 4)
  return math.min(max_width, math.floor(screen_width * 0.9)), math.min(#lines, math.floor(screen_height * 0.85))
end

function M.open(opts)
  local return_win = vim.api.nvim_get_current_win()
  local return_buf = vim.api.nvim_get_current_buf()
  local return_cursor = vim.api.nvim_win_get_cursor(return_win)
  local lines = M.lines(opts.changes, opts.root, opts.warning)
  local width, height = dimensions(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  local title = opts.can_accept
      and " Seal changes · Tab accept · Esc reject · q later "
    or " Seal changes · Esc reject · q later "
  local opened, win = pcall(function()
    vim.api.nvim_buf_set_name(buf, "seal://review/" .. tostring(opts.id))
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    vim.api.nvim_set_option_value("filetype", "diff", { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    local created = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = title,
      title_pos = "center",
      width = width,
      height = math.max(1, height),
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    })
    vim.api.nvim_set_option_value("wrap", false, { win = created })
    return created
  end)
  if not opened then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    error(win, 0)
  end
  local view = {
    buf = buf,
    win = win,
    closed = false,
    return_win = return_win,
    return_buf = return_buf,
    return_cursor = return_cursor,
  }

  function view:close()
    if self.closed then
      return
    end
    self.closed = true
    if vim.api.nvim_win_is_valid(self.win) then
      vim.api.nvim_win_close(self.win, true)
    end
    if vim.api.nvim_buf_is_valid(self.buf) then
      vim.api.nvim_buf_delete(self.buf, { force = true })
    end
  end

  local function decide(decision)
    if view.closed then
      return
    end
    view:close()
    opts.on_decision(decision)
  end

  if opts.can_accept then
    vim.keymap.set("n", "<Tab>", function()
      decide("accept")
    end, { buffer = buf, nowait = true, silent = true, desc = "Accept the proposed Codex patch" })
  end
  vim.keymap.set("n", "<Esc>", function()
    decide("decline")
  end, { buffer = buf, nowait = true, silent = true, desc = "Reject the proposed Codex patch" })
  vim.keymap.set("n", "x", function()
    decide("cancel")
  end, { buffer = buf, nowait = true, silent = true, desc = "Reject the patch and stop the Codex turn" })
  vim.keymap.set("n", "q", function()
    view:close()
    opts.on_defer()
  end, { buffer = buf, nowait = true, silent = true, desc = "Review this patch later" })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if not view.closed then
        view.closed = true
        opts.on_defer()
      end
    end,
  })

  return view
end

return M
