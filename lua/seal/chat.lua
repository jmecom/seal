local M = {}

local function append_text(lines, text)
  vim.list_extend(lines, vim.split(text or "", "\n", { plain = true }))
end

local function append_message(lines, heading, text)
  table.insert(lines, heading)
  table.insert(lines, "")
  append_text(lines, text)
  table.insert(lines, "")
end

local function user_content(content)
  local parts = {}
  for _, input in ipairs(content or {}) do
    if input.type == "text" then
      table.insert(parts, input.text or "")
    elseif input.type == "image" then
      table.insert(parts, "[image attachment]")
    elseif input.type == "localImage" then
      table.insert(parts, "[local image: " .. (input.path or "unknown") .. "]")
    elseif input.type == "skill" then
      table.insert(parts, "[skill: " .. (input.name or "unknown") .. "]")
    elseif input.type == "mention" then
      table.insert(parts, "[mention: " .. (input.name or "unknown") .. "]")
    end
  end
  return table.concat(parts, "\n")
end

local function status_name(status)
  if type(status) == "table" then
    return status.type or "unknown"
  end
  return type(status) == "string" and status or "unknown"
end

function M.render(thread)
  local lines = {
    "# Seal chat",
    "",
    "- Project: `" .. tostring(thread.cwd or "unknown") .. "`",
    "- Thread: `" .. tostring(thread.id or "unknown") .. "`",
    "- Status: `" .. status_name(thread.status) .. "`",
    "",
    "_Read-only conversation view. Tool activity is omitted. Press `r` to refresh and `q` to return._",
    "",
  }
  local messages = 0

  for _, turn in ipairs(thread.turns or {}) do
    for _, item in ipairs(turn.items or {}) do
      if item.type == "userMessage" then
        local text = user_content(item.content)
        if text ~= "" then
          append_message(lines, "## You", text)
          messages = messages + 1
        end
      elseif item.type == "agentMessage" and item.text and item.text ~= "" then
        local heading = item.phase == "commentary" and "### Codex · progress" or "## Codex"
        append_message(lines, heading, item.text)
        messages = messages + 1
      elseif item.type == "contextCompaction" then
        table.insert(lines, "> Codex compacted the conversation context here.")
        table.insert(lines, "")
      end
    end

    if turn.status == "failed" then
      local message = type(turn.error) == "table" and turn.error.message or nil
      table.insert(lines, "> Turn failed" .. (message and ": " .. message or "."))
      table.insert(lines, "")
    end
  end

  if messages == 0 then
    table.insert(lines, "_No messages yet._")
  end
  return lines
end

return M
