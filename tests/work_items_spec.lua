local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local work_items = require("seal.work_items")

local function fail(message)
  error(message, 2)
end

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(value, message)
  if not value then
    fail(message)
  end
end

local tests = {}

function tests.unified_and_legacy_ids_are_stable()
  local store = work_items.new()
  local first = assert(store:create({ kind = "declaration", root = "/one", request = "first" }))
  local activity = assert(store:create({ kind = "agent", root = "/one", request = "second" }))
  local second = assert(store:create({ kind = "declaration", root = "/one", request = "third" }))

  equal({ first.id, activity.id, second.id }, { 1, 2, 3 }, "all work should share one monotonic ID space")
  equal({ first.legacy_id, activity.legacy_id, second.legacy_id }, { 1, 1, 2 }, "legacy IDs should remain per-kind")
  equal(first.job_id, 1, "declarations should carry their old job ID")
  equal(activity.activity_id, 1, "agent work should carry its old activity ID")
  equal(activity.anchor, activity.id, "an item should default to its stable ID as the anchor identity")
  truthy(store.jobs[1] == first, "the jobs compatibility index should contain the canonical object")
  truthy(store.activities[1] == activity, "the activities compatibility index should contain the canonical object")
  truthy(store:get_legacy("declaration", 2) == second, "legacy lookup should select within a kind")

  assert(store:transition(activity, "cancelled"))
  assert(store:remove(activity))
  local next_activity = assert(store:create({ kind = "agent", root = "/one", request = "fourth" }))
  equal(next_activity.id, 4, "removal must not reuse a unified ID")
  equal(next_activity.legacy_id, 2, "removal must not reuse a legacy ID")
end

function tests.scheduler_can_share_the_authoritative_objects()
  local store = work_items.new()
  local item = assert(store:create({ kind = "agent", root = "/repo", request = { prompt = "fix it" } }))
  truthy(store.items[item.id] == item, "the public item table should contain the canonical object")

  local starting = assert(store:transition(item, "starting", { start_token = "attempt-1" }))
  truthy(starting == item, "a transition should mutate and return the canonical object")
  equal(store.items[item.id].state, "starting", "scheduler reads should observe the transition directly")
  assert(store:transition(item.id, "running", { thread_id = "thread-1", turn_id = "turn-1" }))
  equal(item.turn_id, "turn-1", "turn ownership should live on the shared work item")
  equal(item.version, 3, "each real transition should advance the item version")
end

function tests.transition_graph_rejects_invalid_lifecycle_changes()
  local store = work_items.new()
  local item = assert(store:create({ kind = "declaration", root = "/repo", request = "make a type" }))

  local result, err = store:transition(item, "running")
  equal(result, nil, "queued work cannot skip the starting state")
  equal({ err.code, err.item_id, err.from, err.to }, {
    "invalid_transition",
    item.id,
    "queued",
    "running",
  }, "transition errors should identify the violated invariant")
  equal(item.state, "queued", "a rejected transition must not mutate the item")

  local _, state_err = store:transition(item, "mystery")
  equal(state_err.code, "unknown_state", "unknown states should be distinguished from invalid edges")
  local _, item_err = store:transition(999, "cancelled")
  equal(item_err.code, "unknown_item", "unknown IDs should return a structured error")
end

function tests.terminal_transitions_are_idempotent()
  local store = work_items.new()
  local item = assert(store:create({ kind = "agent", root = "/repo", request = "explain" }))
  assert(store:transition(item, "starting"))
  assert(store:transition(item, "running"))
  local terminal, terminal_err, changed = store:transition(item, "done", { result = "finished" })
  truthy(terminal == item and terminal_err == nil and changed, "the first terminal transition should settle the item")
  local version = item.version

  local repeated, repeated_err, repeated_changed = store:transition(item, "done", { result = "late overwrite" })
  truthy(repeated == item and repeated_err == nil, "repeating the same terminal outcome should succeed")
  equal(repeated_changed, false, "an idempotent terminal transition should report no change")
  equal(item.result, "finished", "a repeated notification must not overwrite the first terminal result")
  equal(item.version, version, "an idempotent terminal notification must not advance the version")

  local _, conflict = store:transition(item, "cancelled")
  equal(conflict.code, "invalid_transition", "a different terminal outcome must not replace the first one")
  equal(item.state, "done", "the original terminal outcome should remain authoritative")
end

function tests.preview_payload_survives_a_failed_apply()
  local store = work_items.new()
  local item = assert(store:create({ kind = "declaration", root = "/repo", request = "define storage" }))
  assert(store:transition(item, "starting"))
  assert(store:transition(item, "running"))

  local _, missing = store:transition(item, "preview")
  equal(missing.code, "missing_preview", "generation must provide a preview payload")
  local payload = { lines = { "type Storage = string" }, language = "typescript" }
  assert(store:set_preview(item, payload, { model = "codex" }))
  truthy(item.preview == payload, "the store should retain the exact preview payload")
  assert(store:transition(item, "applying"))
  assert(store:transition(item, "preview", { apply_error = "buffer changed" }))

  equal(item.state, "preview", "an apply failure should return to preview instead of failing the work")
  truthy(item.preview == payload, "returning from apply should preserve the reviewable payload")
  equal(item.apply_error, "buffer changed", "the retryable apply error should remain available to the UI")
  local _, terminal_failure = store:transition(item, "failed")
  equal(terminal_failure.code, "invalid_transition", "a retained preview must not become terminally failed")
end

function tests.ownership_and_compatibility_fields_stay_on_one_object()
  local store = work_items.new()
  local request = { prompt = "write one function" }
  local anchor = { id = "anchor-7" }
  local snapshot = { buf = 12, row = 4 }
  local item = assert(store:create({
    kind = "declaration",
    root = "/repo",
    buffer = 12,
    request = request,
    anchor = anchor,
    fields = {
      snapshot = snapshot,
      phase = "generating",
      declaration_kind = "function",
      extmark = 91,
    },
  }))

  truthy(item.request == request, "request ownership should retain the original object")
  truthy(item.anchor == anchor, "anchor ownership should retain the original object")
  truthy(item.snapshot == snapshot, "compatibility data should be carried on the canonical item")
  truthy(store.jobs[item.legacy_id] == item, "compatibility lookup must not return a projection copy")
  equal({ item.root, item.buffer, item.phase, item.extmark }, {
    "/repo",
    12,
    "generating",
    91,
  }, "the item should expose ownership and legacy UI fields together")

  local rejected, err = store:create({
    kind = "agent",
    root = "/repo",
    request = "bad override",
    fields = { state = "done" },
  })
  equal(rejected, nil, "compatibility fields must not override lifecycle ownership")
  equal(err.code, "immutable_field", "reserved-field failures should be explicit")
  equal(store:count(), 1, "a rejected create must not consume or install an item")

  local preview_override, preview_err = store:create({
    kind = "agent",
    root = "/repo",
    request = "bad preview",
    fields = { preview = "too early" },
  })
  equal(preview_override, nil, "compatibility fields must not bypass the preview transition")
  equal(preview_err.code, "immutable_field", "preview ownership should remain with the lifecycle")
end

function tests.list_and_count_scope_by_root_buffer_kind_and_state()
  local store = work_items.new()
  local one = assert(store:create({ kind = "declaration", root = "/one", buffer = 10, request = "one" }))
  local two = assert(store:create({ kind = "agent", root = "/one", buffer = 20, request = "two" }))
  local three = assert(store:create({ kind = "declaration", root = "/two", buffer = 10, request = "three" }))
  assert(store:transition(two, "cancelled"))

  equal(store:list({ root = "/one" }), { one, two }, "root scope should preserve creation order")
  equal(store:list({ buffer = 10 }), { one, three }, "buffer scope should span projects")
  equal(store:list({ root = "/one", buffer = 10 }), { one }, "root and buffer scopes should compose")
  equal(store:list({ kind = "declaration" }), { one, three }, "kind scope should select legacy groups")
  equal(store:list({ terminal = true }), { two }, "terminal scope should select settled work")
  equal(store:count({ state = "queued" }), 2, "count should accept the same scopes as list")
end

function tests.remove_requires_terminal_state_and_cleans_indexes()
  local store = work_items.new()
  local item = assert(store:create({ kind = "declaration", root = "/repo", buffer = 3, request = "one" }))
  local removed, err = store:remove(item)
  equal(removed, nil, "live work should not disappear from lifecycle tracking")
  equal(err.code, "item_not_terminal", "non-terminal removal should explain the invariant")
  truthy(store:get(item.id) == item, "a rejected removal should leave the item installed")

  assert(store:transition(item, "cancelled"))
  truthy(store:remove(item) == item, "terminal work should be removable")
  equal(store:get(item.id), nil, "removal should clear the unified index")
  equal(store:get_legacy("declaration", item.legacy_id), nil, "removal should clear the legacy index")
  equal(store:count(), 0, "removed work should not appear in list-backed counts")
  equal(store.order, {}, "removal should not retain historical IDs in the ordering index")
end

function tests.retire_hides_terminal_ui_indexes_until_scheduler_release()
  local store = work_items.new()
  local item = assert(store:create({ kind = "agent", root = "/repo", request = "one" }))
  assert(store:transition(item, "cancelled"))
  truthy(store:retire(item) == item, "terminal work should be retireable while a lease still references it")
  truthy(store:get(item.id) == item, "retirement should preserve the canonical scheduler object")
  equal(store:get_legacy("agent", item.legacy_id), nil, "retirement should remove the UI index")
  equal(store:list(), {}, "retirement should remove the item from list-backed admission counts")
  truthy(store:remove(item) == item, "release should purge the retired canonical item")
  equal(store:get(item.id), nil, "purge should clear the canonical index")
end

local order = {
  "unified_and_legacy_ids_are_stable",
  "scheduler_can_share_the_authoritative_objects",
  "transition_graph_rejects_invalid_lifecycle_changes",
  "terminal_transitions_are_idempotent",
  "preview_payload_survives_a_failed_apply",
  "ownership_and_compatibility_fields_stay_on_one_object",
  "list_and_count_scope_by_root_buffer_kind_and_state",
  "remove_requires_terminal_state_and_cleans_indexes",
  "retire_hides_terminal_ui_indexes_until_scheduler_release",
}

for _, name in ipairs(order) do
  tests[name]()
  io.stdout:write("ok - " .. name .. "\n")
end

io.stdout:write(string.format("%d tests passed\n", #order))
