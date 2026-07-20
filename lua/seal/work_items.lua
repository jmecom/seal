local M = {}

local Store = {}
Store.__index = Store

local kinds = {
  declaration = true,
  agent = true,
}

local states = {
  queued = true,
  blocked = true,
  starting = true,
  running = true,
  preview = true,
  applying = true,
  done = true,
  failed = true,
  cancelled = true,
}

local terminal_states = {
  done = true,
  failed = true,
  cancelled = true,
}

local transitions = {
  queued = { blocked = true, starting = true, failed = true, cancelled = true },
  blocked = { queued = true, failed = true, cancelled = true },
  starting = { queued = true, blocked = true, running = true, failed = true, cancelled = true },
  running = { preview = true, done = true, failed = true, cancelled = true },
  preview = { applying = true, done = true, cancelled = true },
  applying = { preview = true, done = true, cancelled = true },
  done = {},
  failed = {},
  cancelled = {},
}

local immutable_fields = {
  id = true,
  work_id = true,
  sequence = true,
  kind = true,
  legacy_id = true,
  job_id = true,
  activity_id = true,
  root = true,
  buffer = true,
  request = true,
  anchor = true,
  preview = true,
  state = true,
  terminal = true,
  version = true,
}

local function work_error(code, message, fields)
  local err = fields or {}
  err.code = code
  err.message = message
  return err
end

local function invalid_transition(item, target, detail)
  return work_error(
    "invalid_transition",
    detail or string.format("cannot transition work item %s from %s to %s", tostring(item.id), item.state, target),
    {
      item_id = item.id,
      from = item.state,
      to = target,
    }
  )
end

local function add_fields(item, fields, allowed_fields)
  if fields == nil then
    return true
  end
  if type(fields) ~= "table" then
    return nil, work_error("invalid_fields", "work item fields must be a table")
  end
  for key in pairs(fields) do
    if immutable_fields[key] and not (allowed_fields and allowed_fields[key]) then
      return nil, work_error(
        "immutable_field",
        "work item field " .. tostring(key) .. " is owned by the store",
        { field = key, item_id = item.id }
      )
    end
  end
  for key, value in pairs(fields) do
    item[key] = value
  end
  return true
end

local function matches(item, scope)
  if scope.root ~= nil and item.root ~= scope.root then
    return false
  end
  if scope.buffer ~= nil and item.buffer ~= scope.buffer then
    return false
  end
  if scope.kind ~= nil and item.kind ~= scope.kind then
    return false
  end
  if scope.state ~= nil and item.state ~= scope.state then
    return false
  end
  if scope.terminal ~= nil and item.terminal ~= scope.terminal then
    return false
  end
  return true
end

function M.is_terminal(state)
  return terminal_states[state] == true
end

function M.can_transition(from, target)
  return transitions[from] ~= nil and transitions[from][target] == true
end

function M.new()
  local declaration_index = {}
  local agent_index = {}
  return setmetatable({
    -- Scheduler and UI code deliberately share these exact objects. Lifecycle
    -- state must not be mirrored into a second scheduler-owned item table.
    items = {},
    jobs = declaration_index,
    activities = agent_index,
    legacy_indexes = {
      declaration = declaration_index,
      agent = agent_index,
    },
    order = {},
    sequence = 0,
    legacy_sequences = {
      declaration = 0,
      agent = 0,
    },
  }, Store)
end

function Store:create(spec)
  if type(spec) ~= "table" then
    return nil, work_error("invalid_spec", "work item spec must be a table")
  end
  if not kinds[spec.kind] then
    return nil, work_error("invalid_kind", "work item kind must be declaration or agent", { kind = spec.kind })
  end
  if type(spec.root) ~= "string" or spec.root == "" then
    return nil, work_error("invalid_root", "work item root must be a non-empty string")
  end
  if spec.request == nil then
    return nil, work_error("invalid_request", "work item request is required")
  end

  local fields = spec.fields or spec.compatibility
  local next_sequence = self.sequence + 1
  local next_legacy = self.legacy_sequences[spec.kind] + 1
  local item = {
    id = next_sequence,
    work_id = next_sequence,
    sequence = next_sequence,
    kind = spec.kind,
    legacy_id = next_legacy,
    root = spec.root,
    buffer = spec.buffer,
    request = spec.request,
    -- The canonical ID is also a useful BufferModel key. Callers may provide
    -- a richer anchor handle, but every item owns an anchor identity even when
    -- the UI has not created an extmark yet.
    anchor = spec.anchor or next_sequence,
    state = "queued",
    terminal = false,
    version = 1,
  }
  if spec.kind == "declaration" then
    item.job_id = next_legacy
  else
    item.activity_id = next_legacy
  end

  local added, fields_err = add_fields(item, fields)
  if not added then
    return nil, fields_err
  end

  self.sequence = next_sequence
  self.legacy_sequences[spec.kind] = next_legacy
  self.items[item.id] = item
  self.legacy_indexes[spec.kind][item.legacy_id] = item
  table.insert(self.order, item.id)
  return item
end

function Store:get(id)
  if type(id) == "table" then
    if id.id ~= nil and self.items[id.id] == id then
      return id
    end
    return nil
  end
  return self.items[id]
end

function Store:get_legacy(kind, legacy_id)
  local index = self.legacy_indexes[kind]
  return index and index[legacy_id] or nil
end

function Store:legacy_index(kind)
  return self.legacy_indexes[kind]
end

function Store:_resolve(id)
  local item = self:get(id)
  if item then
    return item
  end
  local item_id = type(id) == "table" and id.id or id
  return nil, work_error(
    "unknown_item",
    "unknown work item " .. tostring(item_id),
    { item_id = item_id }
  )
end

function Store:transition(id, target, fields)
  local item, resolve_err = self:_resolve(id)
  if not item then
    return nil, resolve_err
  end
  if not states[target] then
    return nil, work_error("unknown_state", "unknown work item state " .. tostring(target), {
      item_id = item.id,
      from = item.state,
      to = target,
    })
  end

  if item.state == target and terminal_states[target] then
    return item, nil, false
  end
  if not transitions[item.state][target] then
    return nil, invalid_transition(item, target)
  end
  if target == "preview" and item.state == "running" and (not fields or fields.preview == nil) then
    return nil, work_error("missing_preview", "running work must provide a preview payload", {
      item_id = item.id,
      from = item.state,
      to = target,
    })
  end

  local added, fields_err = add_fields(item, fields, target == "preview" and { preview = true } or nil)
  if not added then
    return nil, fields_err
  end
  if target == "queued" then
    item.blocked_reason = nil
  end
  item.state = target
  item.terminal = terminal_states[target] == true
  item.version = item.version + 1
  return item, nil, true
end

function Store:set_preview(id, preview, fields)
  fields = fields or {}
  if type(fields) ~= "table" then
    return nil, work_error("invalid_fields", "work item fields must be a table")
  end
  if preview == nil then
    return nil, work_error("missing_preview", "preview payload is required")
  end
  if fields.preview ~= nil and fields.preview ~= preview then
    return nil, work_error("conflicting_preview", "preview payload was provided twice")
  end

  local transition_fields = {}
  for key, value in pairs(fields) do
    transition_fields[key] = value
  end
  transition_fields.preview = preview
  return self:transition(id, "preview", transition_fields)
end

function Store:list(scope)
  scope = scope or {}
  local result = {}
  for _, id in ipairs(self.order) do
    local item = self.items[id]
    if item and matches(item, scope) then
      table.insert(result, item)
    end
  end
  return result
end

function Store:count(scope)
  return #self:list(scope)
end

local function remove_ordered_id(store, id)
  for index, ordered_id in ipairs(store.order) do
    if ordered_id == id then
      table.remove(store.order, index)
      return true
    end
  end
  return false
end

-- Retiring removes a terminal item from UI/list indexes while a scheduler
-- lease still holds its canonical object. `remove` purges it after the lease
-- is released.
function Store:retire(id)
  local item, resolve_err = self:_resolve(id)
  if not item then
    return nil, resolve_err
  end
  if not item.terminal then
    return nil, work_error(
      "item_not_terminal",
      "work item " .. tostring(item.id) .. " must reach a terminal state before retirement",
      { item_id = item.id, state = item.state }
    )
  end
  self.legacy_indexes[item.kind][item.legacy_id] = nil
  remove_ordered_id(self, item.id)
  item.retired = true
  return item
end

function Store:remove(id)
  local item, resolve_err = self:_resolve(id)
  if not item then
    return nil, resolve_err
  end
  if not item.terminal then
    return nil, work_error(
      "item_not_terminal",
      "work item " .. tostring(item.id) .. " must reach a terminal state before removal",
      { item_id = item.id, state = item.state }
    )
  end

  self.items[item.id] = nil
  self.legacy_indexes[item.kind][item.legacy_id] = nil
  remove_ordered_id(self, item.id)
  return item
end

M.Store = Store
M.states = states
M.transitions = transitions
M.terminal_states = terminal_states

return M
