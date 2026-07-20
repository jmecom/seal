local Scheduler = {}
Scheduler.__index = Scheduler
local WorkItems = require("seal.work_items")

-- The scheduler owns FIFO order and turn correlation, not work-item identity.
-- Pass WorkItemStore.items as `registry` and wrap Store:transition as
-- `transition(item, target, context)` to keep lifecycle state on the canonical
-- object. `context.fields` contains metadata for that store transition.

local terminal_states = WorkItems.terminal_states
local transitions = WorkItems.transitions

local turn_outcomes = {
  preview = true,
  done = true,
  failed = true,
  cancelled = true,
}

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values) do
    copy[index] = value
  end
  return copy
end

local function copy_item(item, meta)
  if not item then
    return nil
  end
  meta = meta or {}
  return {
    id = item.id,
    state = item.state,
    sequence = meta.sequence,
    payload = item.payload,
    error = item.error,
    blocked_reason = item.blocked_reason,
    restore_required = meta.restore_required,
  }
end

local function copy_lease(lease)
  if not lease then
    return nil
  end
  return {
    item_id = lease.item_id,
    generation = lease.generation,
    token = lease.token,
    phase = lease.phase,
    turn_id = lease.turn_id,
    dispatched = lease.dispatched,
    restore_required = lease.restore_required,
    restore_done = lease.restore_done,
    restore_ok = lease.restore_ok,
    retry = lease.retry,
    turn_done = lease.turn_done,
  }
end

local function scheduler_error(code, message, fields)
  local err = fields or {}
  err.code = code
  err.message = message
  return err
end

local function invalid_transition(item, target, detail)
  local item_id = item and item.id or nil
  local from = item and item.state or "missing"
  return scheduler_error(
    "invalid_transition",
    detail
      or string.format(
        "cannot transition item %s from %s to %s",
        tostring(item_id),
        tostring(from),
        tostring(target)
      ),
    {
      item_id = item_id,
      from = from,
      to = target,
    }
  )
end

function Scheduler.new(opts)
  opts = opts or {}
  local registry = opts.registry or {}
  return setmetatable({
    items = registry,
    meta = {},
    owns_registry = opts.registry == nil,
    transition_item = opts.transition,
    queue = {},
    current = nil,
    sequence = 0,
    generation = 0,
    pending_turn_events = {},
    block = nil,
    token_prefix = opts.token_prefix or "seal-turn",
  }, Scheduler)
end

function Scheduler:_item(id)
  local item = self.items[id]
  if item and self.meta[id] then
    return item
  end
  return nil, scheduler_error("unknown_item", "unknown scheduler item " .. tostring(id), { item_id = id })
end

function Scheduler:_transition(item, target, detail, context)
  if item.state == target then
    return nil, invalid_transition(item, target, detail or "item is already in state " .. target)
  end
  if not transitions[item.state] or not transitions[item.state][target] then
    return nil, invalid_transition(item, target, detail)
  end
  if self.transition_item then
    local ok, result, err = pcall(self.transition_item, item, target, context or {})
    if not ok then
      return nil, scheduler_error("transition_failed", tostring(result), {
        item_id = item.id,
        from = item.state,
        to = target,
      })
    end
    if result == false or item.state ~= target then
      local message = type(err) == "table" and err.message or err
      return nil, scheduler_error("transition_failed", message or "the external item registry rejected the transition", {
        item_id = item.id,
        from = item.state,
        to = target,
        cause = err,
      })
    end
  else
    item.state = target
  end
  return item
end

function Scheduler:_remove_from_queue(id)
  local removed = false
  local index = 1
  while index <= #self.queue do
    if self.queue[index] == id then
      table.remove(self.queue, index)
      removed = true
    else
      index = index + 1
    end
  end
  return removed
end

function Scheduler:_insert_queued(item)
  self:_remove_from_queue(item.id)
  local inserted = false
  for index, queued_id in ipairs(self.queue) do
    local queued_meta = self.meta[queued_id]
    local item_meta = self.meta[item.id]
    if queued_meta and item_meta and item_meta.sequence < queued_meta.sequence then
      table.insert(self.queue, index, item.id)
      inserted = true
      break
    end
  end
  if not inserted then
    table.insert(self.queue, item.id)
  end
end

function Scheduler:_lease(token)
  local lease = self.current
  if not lease then
    return nil, scheduler_error("no_current_lease", "there is no active scheduler lease", { token = token })
  end
  if lease.token ~= token then
    return nil, scheduler_error("stale_start_attempt", "the start attempt token is no longer current", {
      token = token,
      current_token = lease.token,
      item_id = lease.item_id,
      generation = lease.generation,
    })
  end
  return lease
end

function Scheduler:_release(lease)
  if self.current ~= lease then
    return false
  end
  self.current = nil
  lease.phase = "released"
  return true
end

function Scheduler:_annotate(item, key, value)
  if not self.transition_item then
    item[key] = value
  end
end

function Scheduler:_next_action(fields)
  fields = fields or {}
  fields.next_item_id = not self.current and not self.block and self.queue[1] or nil
  fields.blocked = self.block ~= nil
  return fields
end

function Scheduler:_settle(lease)
  if self.current ~= lease then
    return nil, scheduler_error("stale_start_attempt", "the lease was already released", {
      token = lease.token,
      item_id = lease.item_id,
    })
  end

  local item = self.items[lease.item_id]
  if lease.start_failed then
    -- Restoration is the final barrier for a rejected start attempt. Once it
    -- resolves, always release the lease; only a still-live item is requeued.
    if lease.restore_required and not lease.restore_done then
      return self:_next_action({ waiting_for_restore = true, released = false })
    end

    local requeued = false
    if lease.retry and item and not terminal_states[item.state] then
      if lease.restore_ok == false then
        if item.state ~= "blocked" then
          local _, transition_err = self:_transition(item, "blocked", nil, {
            event = "restore_failed",
            fields = { blocked_reason = lease.restore_error or "settings restoration failed" },
          })
          if transition_err then
            return nil, transition_err
          end
        end
      else
        if item.state ~= "queued" then
          local _, transition_err = self:_transition(item, "queued", nil, {
            event = "retry_ready",
            fields = { retry_generation = lease.generation },
          })
          if transition_err then
            return nil, transition_err
          end
        end
        self:_annotate(item, "blocked_reason", nil)
        self:_insert_queued(item)
        requeued = true
      end
    end
    self:_release(lease)
    return self:_next_action({ released = true, requeued = requeued })
  end

  if not lease.turn_done then
    return self:_next_action({ released = false, waiting_for_turn = true })
  end
  if lease.restore_required and not lease.restore_done then
    return self:_next_action({ released = false, waiting_for_restore = true })
  end

  self:_release(lease)
  return self:_next_action({ released = true, requeued = false })
end

function Scheduler:_enqueue_item(item, opts)
  opts = opts or {}
  local id = item and item.id
  if id == nil then
    return nil, scheduler_error("invalid_item_id", "scheduler item IDs cannot be nil")
  end
  if self.meta[id] then
    return nil, scheduler_error("duplicate_item", "scheduler item already exists: " .. tostring(id), {
      item_id = id,
      state = self.items[id].state,
    })
  end
  if self.items[id] and self.items[id] ~= item then
    return nil, scheduler_error("canonical_item_mismatch", "the registry already has a different canonical item", {
      item_id = id,
    })
  end
  if item.state ~= "queued" then
    return nil, invalid_transition(item, "queued", "items must enter the scheduler in the queued state")
  end

  self.sequence = self.sequence + 1
  self.items[id] = item
  self.meta[id] = {
    sequence = self.sequence,
    restore_required = opts.restore_required == true,
  }
  self:_insert_queued(item)
  return copy_item(item, self.meta[id])
end

function Scheduler:enqueue_item(item, opts)
  if type(item) ~= "table" then
    return nil, scheduler_error("invalid_item", "enqueue_item expects a canonical item table")
  end
  return self:_enqueue_item(item, opts)
end

function Scheduler:enqueue(id, payload, opts)
  if type(id) == "table" then
    return self:enqueue_item(id, payload)
  end
  if id == nil then
    return nil, scheduler_error("invalid_item_id", "scheduler item IDs cannot be nil")
  end
  if not self.owns_registry then
    local canonical = self.items[id]
    if not canonical then
      return nil, scheduler_error("unknown_item", "the external registry has no canonical item " .. tostring(id), {
        item_id = id,
      })
    end
    return self:_enqueue_item(canonical, opts)
  end
  return self:_enqueue_item({ id = id, state = "queued", payload = payload }, opts)
end

function Scheduler:get(id)
  return copy_item(self.items[id], self.meta[id])
end

function Scheduler:canonical_item(id)
  if not self.meta[id] then
    return nil
  end
  return self.items[id]
end

function Scheduler:queue_ids()
  return copy_list(self.queue)
end

function Scheduler:current_lease()
  return copy_lease(self.current)
end

function Scheduler:require_restore(token)
  local lease, lease_err = self:_lease(token)
  if not lease then
    return nil, lease_err
  end
  if lease.phase ~= "starting" or lease.turn_id then
    return nil, scheduler_error("invalid_transition", "restoration can only be required while a turn is starting", {
      item_id = lease.item_id,
      token = token,
      phase = lease.phase,
    })
  end
  lease.restore_required = true
  local meta = self.meta[lease.item_id]
  if meta then
    meta.restore_required = true
  end
  return copy_lease(lease)
end

function Scheduler:blocked_reason()
  return self.block
end

function Scheduler:peek()
  return self.queue[1]
end

function Scheduler:start_next(opts)
  opts = opts or {}
  if self.current then
    return nil, scheduler_error("lease_active", "another scheduler item already owns the turn lease", {
      item_id = self.current.item_id,
      token = self.current.token,
    })
  end
  if self.block then
    return nil, scheduler_error("scheduler_blocked", "the scheduler is blocked", { reason = self.block })
  end

  while #self.queue > 0 do
    local id = table.remove(self.queue, 1)
    local item = self.items[id]
    if item and item.state == "queued" then
      local generation = self.generation + 1
      local token = string.format("%s:%d", self.token_prefix, generation)
      local _, transition_err = self:_transition(item, "starting", nil, {
        event = "start_next",
        fields = { start_token = token, start_generation = generation },
      })
      if transition_err then
        self:_insert_queued(item)
        return nil, transition_err
      end
      self.generation = generation
      local lease = {
        item_id = id,
        generation = generation,
        token = token,
        phase = "starting",
        turn_id = nil,
        dispatched = false,
        restore_required = opts.restore_required == nil and self.meta[id].restore_required
          or opts.restore_required == true,
        restore_done = false,
        restore_ok = nil,
        retry = false,
        turn_done = false,
      }
      self.current = lease
      return copy_lease(lease)
    end
  end
  return nil
end

function Scheduler:mark_start_dispatched(token)
  local lease, lease_err = self:_lease(token)
  if not lease then
    return nil, lease_err
  end
  if lease.phase ~= "starting" or lease.start_failed or lease.turn_id then
    local item = self.items[lease.item_id]
    return nil, invalid_transition(item, "starting", "only an unresolved start attempt can be dispatched")
  end
  if lease.dispatched then
    return nil, scheduler_error("start_already_dispatched", "the start attempt was already dispatched", {
      item_id = lease.item_id,
      token = token,
    })
  end
  lease.dispatched = true
  return copy_lease(lease)
end

function Scheduler:defer_current(token, reason, fields)
  local lease, lease_err = self:_lease(token)
  if not lease then
    return nil, lease_err
  end
  if lease.phase ~= "starting"
    or lease.start_failed
    or lease.turn_id
    or lease.dispatched
    or lease.restore_required
  then
    return nil, scheduler_error(
      "unsafe_defer",
      "only a starting item with no dispatched request or restoration barrier can be deferred",
      {
        item_id = lease.item_id,
        token = token,
        phase = lease.phase,
        turn_id = lease.turn_id,
        dispatched = lease.dispatched,
        restore_required = lease.restore_required,
      }
    )
  end
  if fields ~= nil and type(fields) ~= "table" then
    return nil, scheduler_error("invalid_fields", "defer fields must be a table", { item_id = lease.item_id })
  end

  local item = self.items[lease.item_id]
  if not item or item.state ~= "starting" then
    return nil, invalid_transition(item, "blocked", "the leased item is no longer startable")
  end
  local transition_fields = {}
  for key, value in pairs(fields or {}) do
    transition_fields[key] = value
  end
  transition_fields.blocked_reason = reason
  local _, transition_err = self:_transition(item, "blocked", nil, {
    event = "defer_current",
    fields = transition_fields,
  })
  if transition_err then
    return nil, transition_err
  end
  self:_annotate(item, "blocked_reason", reason)
  self:_release(lease)
  return self:_next_action({
    released = true,
    deferred = true,
    item_id = item.id,
    interrupt_turn_id = nil,
  })
end

function Scheduler:start_succeeded(token, turn_id)
  local lease, lease_err = self:_lease(token)
  if not lease then
    return nil, lease_err
  end
  if lease.phase ~= "starting" or lease.start_failed or lease.turn_id then
    local item = self.items[lease.item_id]
    return nil, invalid_transition(item, "running", "the lease is not waiting for a start response")
  end
  if turn_id == nil or turn_id == "" then
    return nil, scheduler_error("invalid_turn_id", "a successful start response must include a turn ID", {
      item_id = lease.item_id,
      token = token,
    })
  end

  local item = self.items[lease.item_id]
  local abandoned = not item or item.state == "cancelled"
  if item and item.state == "starting" then
    local _, transition_err = self:_transition(item, "running", nil, {
      event = "start_succeeded",
      fields = {
        start_token = token,
        start_generation = lease.generation,
        turn_id = turn_id,
      },
    })
    if transition_err then
      return nil, transition_err
    end
  elseif not abandoned then
    return nil, invalid_transition(item, "running", "the starting item is no longer startable")
  end
  lease.dispatched = true
  lease.turn_id = turn_id
  lease.phase = "running"

  local events = self.pending_turn_events[turn_id] or {}
  -- turn/started can precede the RPC response and does not carry the request's
  -- client ID. Ownership is established here, then buffered events are handed
  -- back to the integration in their original order.
  self.pending_turn_events[turn_id] = nil
  local completed = false
  for _, event in ipairs(events) do
    if event.type == "completed" then
      completed = true
    end
  end

  return self:_next_action({
    lease = copy_lease(lease),
    events = events,
    interrupt_turn_id = abandoned and not completed and turn_id or nil,
    already_completed = completed,
    released = false,
  })
end

function Scheduler:start_failed(token, opts)
  opts = opts or {}
  local lease, lease_err = self:_lease(token)
  if not lease then
    return nil, lease_err
  end
  if lease.phase ~= "starting" or lease.start_failed or lease.turn_id then
    local item = self.items[lease.item_id]
    return nil, invalid_transition(item, opts.retry and "queued" or "failed", "the lease is not starting")
  end

  local retry = opts.retry == true
  local item = self.items[lease.item_id]
  if item and not terminal_states[item.state] then
    local target = retry and "blocked" or "failed"
    local fields = retry
        and { blocked_reason = opts.error or "retry pending", start_error = opts.error }
      or { error = opts.error }
    local _, transition_err = self:_transition(item, target, nil, {
      event = "start_failed",
      retry = retry,
      fields = fields,
    })
    if transition_err then
      return nil, transition_err
    end
    self:_annotate(item, "error", opts.error)
    if target == "blocked" then
      self:_annotate(item, "blocked_reason", opts.error or "retry pending")
    end
  end
  lease.start_failed = true
  lease.dispatched = true
  lease.retry = retry
  lease.phase = lease.restore_required and "finalizing" or "starting"
  lease.error = opts.error
  return self:_settle(lease)
end

function Scheduler:restore_finished(token, ok, err)
  local lease, lease_err = self:_lease(token)
  if not lease then
    return nil, lease_err
  end
  if not lease.restore_required then
    return nil, scheduler_error("restore_not_required", "this lease does not require settings restoration", {
      item_id = lease.item_id,
      token = token,
    })
  end
  if lease.restore_done then
    return nil, scheduler_error("restore_already_finished", "settings restoration already finished", {
      item_id = lease.item_id,
      token = token,
    })
  end

  lease.restore_done = true
  lease.restore_ok = ok == true
  lease.restore_error = err
  if not lease.restore_ok then
    self.block = {
      code = "restore_failed",
      message = err or "settings restoration failed",
      item_id = lease.item_id,
      token = token,
    }
  end
  return self:_settle(lease)
end

function Scheduler:record_turn_started(turn_id, payload)
  return self:_record_turn_event("started", turn_id, payload)
end

function Scheduler:record_turn_completed(turn_id, payload)
  return self:_record_turn_event("completed", turn_id, payload)
end

function Scheduler:record_event(kind, turn_id, payload)
  if type(kind) ~= "string" or kind == "" then
    return nil, scheduler_error("invalid_event", "buffered turn events require a non-empty kind")
  end
  return self:_record_turn_event(kind, turn_id, payload)
end

function Scheduler:_record_turn_event(kind, turn_id, payload)
  if turn_id == nil or turn_id == "" then
    return nil, scheduler_error("invalid_turn_id", "turn notifications must include a turn ID")
  end
  local event = { type = kind, turn_id = turn_id, payload = payload }
  local lease = self.current
  if lease and lease.turn_id == turn_id then
    return {
      owned = true,
      buffered = false,
      item_id = lease.item_id,
      token = lease.token,
      event = event,
    }
  end
  local pending = self.pending_turn_events[turn_id]
  if not pending then
    pending = {}
    self.pending_turn_events[turn_id] = pending
  end
  table.insert(pending, event)
  return { owned = false, buffered = true, event = event }
end

function Scheduler:discard_turn_events(turn_id)
  local events = self.pending_turn_events[turn_id]
  self.pending_turn_events[turn_id] = nil
  return events or {}
end

function Scheduler:finish_turn(turn_id, outcome, fields)
  local lease = self.current
  if not lease or not lease.turn_id then
    return nil, scheduler_error("unowned_turn", "no bound scheduler turn can finish", { turn_id = turn_id })
  end
  if lease.turn_id ~= turn_id then
    return nil, scheduler_error("unowned_turn", "the completed turn does not own the scheduler lease", {
      turn_id = turn_id,
      owned_turn_id = lease.turn_id,
      item_id = lease.item_id,
    })
  end
  if lease.turn_done then
    return nil, scheduler_error("turn_already_finished", "the scheduler turn already finished", {
      turn_id = turn_id,
      item_id = lease.item_id,
    })
  end
  outcome = outcome or "done"
  if not turn_outcomes[outcome] then
    return nil, scheduler_error("invalid_turn_outcome", "unsupported turn outcome " .. tostring(outcome), {
      turn_id = turn_id,
      outcome = outcome,
    })
  end

  if fields ~= nil and type(fields) ~= "table" then
    fields = { error = fields }
  end

  local item = self.items[lease.item_id]
  if item and item.state ~= "cancelled" then
    local _, transition_err = self:_transition(item, outcome, nil, {
      event = "finish_turn",
      turn_id = turn_id,
      fields = fields,
    })
    if transition_err then
      return nil, transition_err
    end
    self:_annotate(item, "error", fields and fields.error or nil)
  end
  lease.turn_done = true
  lease.phase = "finalizing"
  return self:_settle(lease)
end

function Scheduler:cancel(id, reason)
  local item, item_err = self:_item(id)
  if not item then
    return nil, item_err
  end
  if terminal_states[item.state] then
    return nil, invalid_transition(item, "cancelled", "terminal scheduler items cannot be cancelled again")
  end

  local was_queued = self:_remove_from_queue(id)
  local lease = self.current and self.current.item_id == id and self.current or nil
  local previous = item.state
  local _, transition_err = self:_transition(item, "cancelled", nil, {
    event = "cancel",
    fields = { cancel_reason = reason },
  })
  if transition_err then
    if was_queued and item.state == "queued" then
      self:_insert_queued(item)
    end
    return nil, transition_err
  end
  self:_annotate(item, "error", reason)

  if not lease then
    return self:_next_action({ released = false, interrupt_turn_id = nil, cancelled_from = previous })
  end
  if lease.turn_id and not lease.turn_done then
    return self:_next_action({
      released = false,
      interrupt_turn_id = lease.turn_id,
      cancelled_from = previous,
      awaiting_turn = true,
    })
  end
  -- A starting attempt has no safe interrupt target. Keep its lease until the
  -- response either fails or provides the exact turn ID to interrupt.
  return self:_next_action({
    released = false,
    interrupt_turn_id = nil,
    cancelled_from = previous,
    awaiting_start = lease.phase == "starting" and lease.turn_id == nil,
    awaiting_finalization = lease.phase == "finalizing",
  })
end

function Scheduler:block_item(id, reason)
  local item, item_err = self:_item(id)
  if not item then
    return nil, item_err
  end
  if self.current and self.current.item_id == id then
    return nil, invalid_transition(item, "blocked", "a leased item must finish or retry before it can be blocked")
  end
  local was_queued = self:_remove_from_queue(id)
  local _, transition_err = self:_transition(item, "blocked", nil, {
    event = "block_item",
    fields = { blocked_reason = reason },
  })
  if transition_err then
    if was_queued and item.state == "queued" then
      self:_insert_queued(item)
    end
    return nil, transition_err
  end
  self:_annotate(item, "blocked_reason", reason)
  return copy_item(item, self.meta[id])
end

function Scheduler:unblock_item(id)
  local item, item_err = self:_item(id)
  if not item then
    return nil, item_err
  end
  local _, transition_err = self:_transition(item, "queued", nil, { event = "unblock_item" })
  if transition_err then
    return nil, transition_err
  end
  self:_annotate(item, "blocked_reason", nil)
  self:_insert_queued(item)
  return copy_item(item, self.meta[id])
end

function Scheduler:set_block(reason)
  if self.block then
    return nil, scheduler_error("scheduler_blocked", "the scheduler is already blocked", { reason = self.block })
  end
  self.block = reason or { code = "blocked", message = "scheduler blocked" }
  return self.block
end

function Scheduler:clear_block(opts)
  opts = opts or {}
  local previous = self.block
  self.block = nil
  local requeued = {}
  if opts.requeue_items then
    local blocked = {}
    for id in pairs(self.meta) do
      local item = self.items[id]
      if item and item.state == "blocked" and not (self.current and self.current.item_id == item.id) then
        table.insert(blocked, item)
      end
    end
    table.sort(blocked, function(left, right)
      return self.meta[left.id].sequence < self.meta[right.id].sequence
    end)
    for _, item in ipairs(blocked) do
      local transitioned, transition_err = self:_transition(item, "queued", nil, {
        event = "clear_block",
      })
      if not transitioned then
        self.block = previous
        return nil, transition_err
      end
      self:_annotate(item, "blocked_reason", nil)
      self:_insert_queued(item)
      table.insert(requeued, item.id)
    end
  end
  return self:_next_action({ previous = previous, requeued = requeued })
end

function Scheduler:begin_apply(id)
  local item, item_err = self:_item(id)
  if not item then
    return nil, item_err
  end
  local _, transition_err = self:_transition(item, "applying", nil, { event = "begin_apply" })
  if transition_err then
    return nil, transition_err
  end
  return copy_item(item, self.meta[id])
end

function Scheduler:apply_succeeded(id)
  local item, item_err = self:_item(id)
  if not item then
    return nil, item_err
  end
  local _, transition_err = self:_transition(item, "done", nil, { event = "apply_succeeded" })
  if transition_err then
    return nil, transition_err
  end
  return copy_item(item, self.meta[id])
end

function Scheduler:apply_failed(id, err)
  local item, item_err = self:_item(id)
  if not item then
    return nil, item_err
  end
  local _, transition_err = self:_transition(item, "preview", nil, {
    event = "apply_failed",
    fields = { apply_error = err },
  })
  if transition_err then
    return nil, transition_err
  end
  self:_annotate(item, "error", err)
  return copy_item(item, self.meta[id])
end

function Scheduler:forget(id)
  local meta = self.meta[id]
  if not meta then
    return nil, scheduler_error("unknown_item", "unknown scheduler item " .. tostring(id), { item_id = id })
  end
  local item = self.items[id]
  if item and not terminal_states[item.state] then
    return nil, scheduler_error("item_not_terminal", "only terminal scheduler items can be forgotten", {
      item_id = id,
      state = item.state,
    })
  end
  if self.current and self.current.item_id == id then
    return nil, scheduler_error("lease_active", "cannot forget an item while its turn lease is active", {
      item_id = id,
      token = self.current.token,
    })
  end
  self:_remove_from_queue(id)
  self.meta[id] = nil
  if self.owns_registry then
    self.items[id] = nil
  end
  return true
end

function Scheduler:validate()
  local seen = {}
  for index, id in ipairs(self.queue) do
    if seen[id] then
      return nil, scheduler_error("invariant_violation", "queue contains a duplicate item ID", {
        item_id = id,
        index = index,
      })
    end
    seen[id] = true
    local item = self.items[id]
    if not item or item.state ~= "queued" then
      return nil, scheduler_error("invariant_violation", "queue contains an item that is not queued", {
        item_id = id,
        state = item and item.state or nil,
      })
    end
  end
  if self.current then
    if seen[self.current.item_id] then
      return nil, scheduler_error("invariant_violation", "the leased item is still in the queue", {
        item_id = self.current.item_id,
      })
    end
    if not self.items[self.current.item_id] then
      return nil, scheduler_error("invariant_violation", "the turn lease references a missing item", {
        item_id = self.current.item_id,
      })
    end
  end
  return true
end

return Scheduler
