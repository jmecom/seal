local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)/tests/[^/]+$") or source:match("^(.*)tests/[^/]+$") or "."
root = root:gsub("/$", "")
if root == "" then
  root = "."
end
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local Scheduler = require("seal.scheduler")
local WorkItems = require("seal.work_items")

local function fail(message)
  error(message, 2)
end

local function equal(actual, expected, message)
  local function same(left, right, seen)
    if type(left) ~= type(right) then
      return false
    end
    if type(left) ~= "table" then
      return left == right
    end
    seen = seen or {}
    if seen[left] == right then
      return true
    end
    seen[left] = right
    for key, value in pairs(left) do
      if not same(value, right[key], seen) then
        return false
      end
    end
    for key in pairs(right) do
      if left[key] == nil then
        return false
      end
    end
    return true
  end

  if not same(actual, expected) then
    fail(message .. "\nexpected: " .. tostring(expected) .. "\nactual:   " .. tostring(actual))
  end
end

local function truthy(value, message)
  if not value then
    fail(message)
  end
end

local function error_code(value, expected, message)
  truthy(type(value) == "table", message .. ": expected a structured error")
  equal(value.code, expected, message)
end

local tests = {}

function tests.queue_contains_ids_and_issues_one_lease()
  local scheduler = Scheduler.new({ token_prefix = "test" })
  scheduler:enqueue("first", { prompt = "one" })
  scheduler:enqueue("second", { prompt = "two" })

  equal(scheduler:queue_ids(), { "first", "second" }, "the FIFO should contain item IDs in submission order")
  equal(type(scheduler.queue[1]), "string", "the internal queue should store an ID, not an item table")

  local lease = scheduler:start_next()
  equal(lease.item_id, "first", "the first queued item should get the lease")
  equal(lease.generation, 1, "the first start attempt should get generation one")
  equal(lease.token, "test:1", "the attempt should expose an opaque token")
  equal(lease.turn_id, nil, "a start attempt must not own a turn before the response")
  equal(scheduler:get("first").state, "starting", "the leased item should enter starting")
  equal(scheduler:queue_ids(), { "second" }, "leasing should eagerly remove the item from the queue")

  local next_lease, lease_err = scheduler:start_next()
  equal(next_lease, nil, "a second lease should not be issued")
  error_code(lease_err, "lease_active", "one current lease must be enforced")
  truthy(scheduler:validate(), "the scheduler invariants should hold")
end

function tests.external_registry_owns_the_canonical_lifecycle()
  local canonical = { id = "canonical", state = "queued", prompt = "make a function" }
  local registry = { canonical = canonical }
  local observed = {}
  local scheduler = Scheduler.new({
    registry = registry,
    transition = function(item, target)
      table.insert(observed, { item = item, from = item.state, to = target })
      item.state = target
      return true
    end,
  })

  scheduler:enqueue("canonical")
  equal(scheduler:canonical_item("canonical"), canonical, "the scheduler should retain the store's canonical object")
  equal(scheduler:queue_ids(), { "canonical" }, "an external item should still queue by ID")
  local lease = scheduler:start_next()
  equal(canonical.state, "starting", "the external transition function should own lifecycle mutation")
  equal(observed[1].item, canonical, "transitions should receive the canonical object")
  scheduler:start_succeeded(lease.token, "canonical-turn")
  equal(canonical.state, "running", "turn binding should update the same canonical object")
  scheduler:finish_turn("canonical-turn", "preview")
  equal(canonical.state, "preview", "turn completion should remain visible in the external store")
  equal(scheduler.items, registry, "the scheduler must not copy the external registry")
end

function tests.external_transition_failure_preserves_the_fifo()
  local canonical = { id = "canonical", state = "queued" }
  local scheduler = Scheduler.new({
    registry = { canonical = canonical },
    transition = function()
      return false, "store rejected transition"
    end,
  })
  scheduler:enqueue("canonical")

  local lease, transition_err = scheduler:start_next()
  equal(lease, nil, "a rejected canonical transition should not issue a lease")
  error_code(transition_err, "transition_failed", "store failures should be structured")
  equal(scheduler:queue_ids(), { "canonical" }, "a rejected start transition must not lose the queued ID")
  equal(canonical.state, "queued", "the scheduler must not mutate state behind the external store")
end

function tests.work_item_store_integration_keeps_one_lifecycle()
  local store = WorkItems.new()
  local item = assert(store:create({
    kind = "declaration",
    root = "/repo",
    request = "define storage",
  }))
  local scheduler = Scheduler.new({
    registry = store.items,
    transition = function(canonical, target, context)
      return store:transition(canonical, target, context.fields)
    end,
  })
  scheduler:enqueue_item(item)

  local lease = scheduler:start_next()
  truthy(store:get(item.id) == scheduler:canonical_item(item.id), "store and scheduler should expose one object")
  equal(item.start_token, lease.token, "start-attempt metadata should be written through the store")
  scheduler:start_succeeded(lease.token, "store-turn")
  equal(item.turn_id, "store-turn", "confirmed ownership should live on the canonical item")

  local preview = { lines = { "type Storage = string" } }
  scheduler:finish_turn("store-turn", "preview", { preview = preview })
  truthy(item.preview == preview and item.state == "preview", "preview payload and state should stay store-owned")
  scheduler:begin_apply(item.id)
  scheduler:apply_failed(item.id, "E21")
  equal(item.state, "preview", "a failed apply should return the canonical item to preview")
  equal(item.apply_error, "E21", "the store should retain the retryable apply error")
end

function tests.starting_cancellation_waits_for_a_confirmed_turn()
  local scheduler = Scheduler.new()
  scheduler:enqueue("cancel-me")
  scheduler:enqueue("sibling")
  local lease = scheduler:start_next()

  local cancellation = scheduler:cancel("cancel-me", "user rejected")
  equal(cancellation.interrupt_turn_id, nil, "cancelling a starting item must never guess an interrupt target")
  truthy(cancellation.awaiting_start, "the cancelled item should retain its lease until start resolves")
  equal(scheduler:get("cancel-me").state, "cancelled", "the item should become cancelled immediately")
  equal(scheduler:queue_ids(), { "sibling" }, "cancellation must not remove or reorder a sibling")
  truthy(scheduler:current_lease() ~= nil, "the unresolved attempt should continue to hold the only lease")

  local started = scheduler:start_succeeded(lease.token, "confirmed-turn")
  equal(
    started.interrupt_turn_id,
    "confirmed-turn",
    "a late successful response should return the confirmed turn ID for interruption"
  )
  equal(scheduler:current_lease().turn_id, "confirmed-turn", "only the response should bind turn ownership")

  local completed = scheduler:record_turn_completed("confirmed-turn", { status = "interrupted" })
  truthy(completed.owned, "notifications should correlate after the response binds the turn")
  local settled = scheduler:finish_turn("confirmed-turn", "cancelled")
  truthy(settled.released, "the interrupted turn should release its lease")
  equal(settled.next_item_id, "sibling", "the sibling should be immediately eligible")
  equal(scheduler:get("sibling").state, "queued", "the sibling must remain queued")
end

function tests.preflight_deferral_blocks_and_requeues_in_fifo_order()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first")
  scheduler:enqueue("second")
  scheduler:enqueue("third")
  local first_attempt = scheduler:start_next()

  local deferred = scheduler:defer_current(first_attempt.token, "save dirty buffers")
  truthy(deferred.released and deferred.deferred, "preflight deferral should release the current lease")
  equal(deferred.interrupt_turn_id, nil, "an undispatched start must never request an interrupt")
  equal(scheduler:current_lease(), nil, "the blocked item must stop owning the lease")
  equal(scheduler:get("first").state, "blocked", "the deferred item should remain tracked as blocked")
  equal(scheduler:queue_ids(), { "second", "third" }, "deferral should not drop or reorder queued siblings")

  local second_attempt = scheduler:start_next()
  scheduler:start_succeeded(second_attempt.token, "second-turn")
  scheduler:unblock_item("first")
  equal(
    scheduler:queue_ids(),
    { "first", "third" },
    "unblocking should restore original FIFO priority without preempting the current lease"
  )
  scheduler:finish_turn("second-turn", "done")
  equal(scheduler:start_next().item_id, "first", "the unblocked item should run before later submissions")
end

function tests.dispatched_or_running_work_cannot_be_deferred()
  local scheduler = Scheduler.new()
  scheduler:enqueue("dispatched")
  local lease = scheduler:start_next()
  local marked = scheduler:mark_start_dispatched(lease.token)
  truthy(marked.dispatched, "the lease should record when turn/start has been sent")

  local deferred, dispatched_err = scheduler:defer_current(lease.token, "too late")
  equal(deferred, nil, "a dispatched attempt must retain its lease")
  error_code(dispatched_err, "unsafe_defer", "dispatched deferral should fail explicitly")
  equal(scheduler:get("dispatched").state, "starting", "rejected deferral must not mutate the item")
  equal(scheduler:current_lease().token, lease.token, "rejected deferral must not release the lease")

  scheduler:start_succeeded(lease.token, "running-turn")
  local running, running_err = scheduler:defer_current(lease.token, "also too late")
  equal(running, nil, "running work cannot be converted into a preflight block")
  error_code(running_err, "unsafe_defer", "running deferral should fail explicitly")
  equal(scheduler:get("dispatched").state, "running", "the running item should remain authoritative")
  equal(scheduler:current_lease().turn_id, "running-turn", "the owned turn must remain attached")
  scheduler:finish_turn("running-turn", "done")

  local guarded = Scheduler.new()
  guarded:enqueue("guarded", nil, { restore_required = true })
  local guarded_lease = guarded:start_next()
  local blocked, restore_err = guarded:defer_current(guarded_lease.token, "unsafe release")
  equal(blocked, nil, "a restoration barrier must prevent immediate lease release")
  error_code(restore_err, "unsafe_defer", "restoration-aware deferral should fail explicitly")
  guarded:start_failed(guarded_lease.token, { error = "not sent" })
  guarded:restore_finished(guarded_lease.token, true)
end

function tests.canonical_preflight_deferral_preserves_the_work_item()
  local store = WorkItems.new()
  local item = assert(store:create({ kind = "agent", root = "/repo", request = "fix it" }))
  local scheduler = Scheduler.new({
    registry = store.items,
    transition = function(canonical, target, context)
      return store:transition(canonical, target, context.fields)
    end,
  })
  scheduler:enqueue_item(item)
  local lease = scheduler:start_next()
  scheduler:defer_current(lease.token, "dirty buffer", { preflight_error = "save first" })

  truthy(scheduler:canonical_item(item.id) == item, "deferral should retain the exact canonical item")
  equal(item.state, "blocked", "the WorkItemStore should own the blocked lifecycle")
  equal(item.blocked_reason, "dirty buffer", "the block reason should be available to the UI")
  equal(item.preflight_error, "save first", "preflight details should pass through the canonical transition")
  scheduler:unblock_item(item.id)
  equal(item.state, "queued", "the same canonical item should become queueable after recovery")
  equal(scheduler:queue_ids(), { item.id }, "recovery should reinsert only its ID")
end

function tests.restore_requirement_begins_only_when_policy_changes()
  local scheduler = Scheduler.new()
  scheduler:enqueue("declaration")
  local lease = scheduler:start_next()
  truthy(not lease.restore_required, "preflight should begin without a restoration obligation")
  local guarded = assert(scheduler:require_restore(lease.token))
  truthy(guarded.restore_required, "policy override should add the restoration barrier")
  scheduler:start_failed(lease.token, { error = "start failed" })
  local settled = scheduler:restore_finished(lease.token, true)
  truthy(settled.released, "restoring a failed policy override should release the lease")
end

function tests.removed_cancelled_item_still_releases_its_late_turn()
  local store = WorkItems.new()
  local item = assert(store:create({ kind = "agent", root = "/repo", request = "cancel me" }))
  local scheduler = Scheduler.new({
    registry = store.items,
    transition = function(canonical, target, context)
      return store:transition(canonical, target, context.fields)
    end,
  })
  scheduler:enqueue_item(item)
  local lease = scheduler:start_next()
  scheduler:cancel(item.id)
  assert(store:remove(item))

  local late = scheduler:start_succeeded(lease.token, "late-turn")
  equal(late.interrupt_turn_id, "late-turn", "a removed item should still yield its confirmed interrupt target")
  local settled = scheduler:finish_turn("late-turn", "cancelled")
  truthy(settled.released, "the late turn should release even when its canonical item is gone")
  equal(scheduler:current_lease(), nil, "removed work must not wedge the lease")
end

function tests.early_turn_notifications_replay_after_binding()
  local scheduler = Scheduler.new()
  scheduler:enqueue("declaration")
  local lease = scheduler:start_next()

  local early_started = scheduler:record_turn_started("turn-a", { sequence = 1 })
  local early_completed = scheduler:record_turn_completed("turn-a", { sequence = 2, status = "completed" })
  truthy(early_started.buffered and early_completed.buffered, "pre-response notifications should be buffered")
  equal(scheduler:current_lease().turn_id, nil, "notifications alone must not claim a turn")

  scheduler:record_turn_started("external-turn", { sequence = 3 })
  local bound = scheduler:start_succeeded(lease.token, "turn-a")
  equal(#bound.events, 2, "binding should return every buffered event for replay")
  equal(bound.events[1].type, "started", "events should preserve arrival order")
  equal(bound.events[2].type, "completed", "completion should replay after start")
  truthy(bound.already_completed, "binding should identify an already-completed turn")
  equal(#scheduler:discard_turn_events("external-turn"), 1, "unrelated TUI events should remain separately discardable")

  local finished = scheduler:finish_turn("turn-a", "preview")
  truthy(finished.released, "replaying completion should release the lease")
  equal(scheduler:get("declaration").state, "preview", "the completed declaration should enter preview")

  scheduler:begin_apply("declaration")
  equal(scheduler:get("declaration").state, "applying", "acceptance should enter applying")
  scheduler:apply_succeeded("declaration")
  equal(scheduler:get("declaration").state, "done", "a successful insertion should finish the item")
end

function tests.failed_apply_returns_to_preview()
  local scheduler = Scheduler.new()
  scheduler:enqueue("proposal")
  local lease = scheduler:start_next()
  scheduler:start_succeeded(lease.token, "proposal-turn")
  scheduler:finish_turn("proposal-turn", "preview")
  scheduler:begin_apply("proposal")

  local item = scheduler:apply_failed("proposal", "buffer is not modifiable")
  equal(item.state, "preview", "a failed editor apply should retain the proposal for another attempt")
  equal(scheduler:get("proposal").error, "buffer is not modifiable", "the apply error should remain inspectable")
  scheduler:begin_apply("proposal")
  scheduler:apply_succeeded("proposal")
  equal(scheduler:get("proposal").state, "done", "the retained proposal should be applicable later")
end

function tests.cancelled_early_completion_needs_no_interrupt()
  local scheduler = Scheduler.new()
  scheduler:enqueue("fast")
  local lease = scheduler:start_next()
  scheduler:cancel("fast")
  scheduler:record_turn_started("fast-turn")
  scheduler:record_turn_completed("fast-turn", { status = "completed" })

  local bound = scheduler:start_succeeded(lease.token, "fast-turn")
  equal(bound.interrupt_turn_id, nil, "an already-completed turn should not be interrupted")
  truthy(bound.already_completed, "the late response should report buffered completion")
  scheduler:finish_turn("fast-turn", "cancelled")
  equal(scheduler:current_lease(), nil, "replayed completion should release the cancelled start")
end

function tests.retry_requeues_by_original_fifo_order_after_restore()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first", nil, { restore_required = true })
  scheduler:enqueue("second")
  local first_attempt = scheduler:start_next()

  local failed = scheduler:start_failed(first_attempt.token, {
    retry = true,
    error = "an external turn won the race",
  })
  truthy(failed.waiting_for_restore, "the failed declaration start should wait for policy restoration")
  equal(scheduler:get("first").state, "blocked", "a retry should be explicitly blocked during restoration")
  equal(scheduler:queue_ids(), { "second" }, "the leased ID should stay out of the queue while restoring")

  local restored = scheduler:restore_finished(first_attempt.token, true)
  truthy(restored.released and restored.requeued, "successful restoration should release and requeue the item")
  equal(scheduler:queue_ids(), { "first", "second" }, "retry should retain original FIFO priority")

  local second_attempt = scheduler:start_next()
  equal(second_attempt.item_id, "first", "the same item should receive the retry lease")
  equal(second_attempt.generation, 2, "a retry must use a new generation")
  truthy(second_attempt.token ~= first_attempt.token, "a retry must use a new token")
  truthy(not second_attempt.restore_required, "a restored attempt must not carry its old restoration barrier")
  local _, stale_err = scheduler:start_succeeded(first_attempt.token, "stale-turn")
  error_code(stale_err, "stale_start_attempt", "an old response must not bind the retry lease")

  scheduler:require_restore(second_attempt.token)
  scheduler:start_succeeded(second_attempt.token, "retry-turn")
  scheduler:restore_finished(second_attempt.token, true)
  scheduler:finish_turn("retry-turn", "done")
  equal(scheduler:peek(), "second", "the next submitted item should follow a successful retry")
end

function tests.dead_retry_still_releases_after_restore()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first", nil, { restore_required = true })
  scheduler:enqueue("second")
  local lease = scheduler:start_next()
  scheduler:start_failed(lease.token, { retry = true, error = "busy" })

  local cancellation = scheduler:cancel("first")
  equal(cancellation.interrupt_turn_id, nil, "a failed start has no turn to interrupt")
  truthy(cancellation.awaiting_finalization, "the dead item should wait only for restoration")
  equal(scheduler:queue_ids(), { "second" }, "the dead retry must be removed eagerly")

  local restored = scheduler:restore_finished(lease.token, true)
  truthy(restored.released, "restoration must release a lease even after its item dies")
  truthy(not restored.requeued, "a cancelled item must not be resurrected")
  equal(scheduler:current_lease(), nil, "the dead retry must not wedge the current lease")
  equal(scheduler:start_next().item_id, "second", "the live sibling should be able to start")
end

function tests.failed_restore_blocks_but_releases_the_lease()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first", nil, { restore_required = true })
  scheduler:enqueue("second")
  local lease = scheduler:start_next()
  scheduler:start_succeeded(lease.token, "turn-one")

  local restore = scheduler:restore_finished(lease.token, false, "restore failed")
  truthy(restore.waiting_for_turn, "a live turn must finish even after restoration fails")
  error_code(scheduler:blocked_reason(), "restore_failed", "a failed restore should block unsafe starts")
  local finished = scheduler:finish_turn("turn-one", "preview")
  truthy(finished.released, "turn completion must release the lease after a failed restore")
  equal(scheduler:get("first").state, "preview", "the completed result should remain reviewable")

  local next_lease, blocked_err = scheduler:start_next()
  equal(next_lease, nil, "the next item must not inherit unsafe settings")
  error_code(blocked_err, "scheduler_blocked", "the restore failure should stop dispatch")
  scheduler:clear_block()
  equal(scheduler:start_next().item_id, "second", "explicit recovery should allow queued work to continue")
end

function tests.queued_cancellation_is_eager_and_does_not_touch_siblings()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first")
  scheduler:enqueue("second")
  scheduler:enqueue("third")
  local cancellation = scheduler:cancel("second")

  equal(cancellation.interrupt_turn_id, nil, "a queued item has no turn to interrupt")
  equal(scheduler:queue_ids(), { "first", "third" }, "queued cancellation should remove the ID immediately")
  equal(scheduler:get("second").state, "cancelled", "the cancelled item should be terminal")
  equal(scheduler:start_next().item_id, "first", "the first sibling should keep its position")
  truthy(scheduler:validate(), "eager cancellation should preserve scheduler invariants")
end

function tests.running_cancellation_targets_only_the_owned_turn()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first")
  scheduler:enqueue("second")
  local lease = scheduler:start_next()
  scheduler:start_succeeded(lease.token, "owned-turn")

  local cancellation = scheduler:cancel("first")
  equal(cancellation.interrupt_turn_id, "owned-turn", "running cancellation should name the confirmed owned turn")
  equal(scheduler:queue_ids(), { "second" }, "the sibling should stay queued")
  truthy(scheduler:current_lease() ~= nil, "the cancelled turn should retain its lease until completion")

  scheduler:finish_turn("owned-turn", "cancelled")
  equal(scheduler:start_next().item_id, "second", "completion should hand the lease to the sibling")
end

function tests.blocked_items_are_removed_and_can_be_requeued()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first")
  scheduler:enqueue("second")
  scheduler:block_item("first", "wait for external state")
  equal(scheduler:queue_ids(), { "second" }, "blocking should eagerly remove an item from the FIFO")
  equal(scheduler:get("first").state, "blocked", "the item should expose its blocked lifecycle")
  scheduler:unblock_item("first")
  equal(scheduler:queue_ids(), { "first", "second" }, "unblocking should restore submission order")
end

function tests.leased_blocked_item_cannot_be_unblocked()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first", nil, { restore_required = true })
  local lease = scheduler:start_next()
  scheduler:start_failed(lease.token, { retry = true, error = "busy" })

  local unblocked, err = scheduler:unblock_item("first")
  equal(unblocked, nil, "a finalizing lease must remain out of the queue")
  error_code(err, "invalid_transition", "leased unblock should fail explicitly")
  equal(scheduler:queue_ids(), {}, "the leased item must not also appear in the queue")
  truthy(scheduler:validate(), "rejected unblock must preserve scheduler invariants")
  scheduler:restore_finished(lease.token, true)
end

function tests.clear_block_requeues_only_unleased_blocked_items()
  local scheduler = Scheduler.new()
  scheduler:enqueue("first")
  scheduler:enqueue("second")
  scheduler:block_item("first", "restore failed")
  scheduler:set_block({ code = "restore_failed" })

  local action = scheduler:clear_block({ requeue_items = true })
  equal(action.requeued, { "first" }, "clear_block should report the items it made runnable")
  equal(scheduler:queue_ids(), { "first", "second" },
    "recovery should restore original FIFO order without duplicating siblings")
  truthy(scheduler:validate(), "clear_block recovery should preserve scheduler invariants")
end

function tests.invalid_transitions_return_structured_errors()
  local scheduler = Scheduler.new()
  scheduler:enqueue("item")
  local applied, apply_err = scheduler:begin_apply("item")
  equal(applied, nil, "queued work cannot be applied")
  error_code(apply_err, "invalid_transition", "invalid lifecycle changes should be explicit")
  equal(apply_err.from, "queued", "the error should identify the source state")
  equal(apply_err.to, "applying", "the error should identify the requested state")

  local lease = scheduler:start_next()
  local started, turn_err = scheduler:start_succeeded(lease.token, "")
  equal(started, nil, "a response without a turn ID must be rejected")
  error_code(turn_err, "invalid_turn_id", "turn binding errors should be structured")
  scheduler:start_failed(lease.token, { error = "request failed" })
  equal(scheduler:get("item").state, "failed", "a non-retryable start should enter failed")

  local cancelled, cancel_err = scheduler:cancel("item")
  equal(cancelled, nil, "terminal work cannot be cancelled again")
  error_code(cancel_err, "invalid_transition", "terminal cancellation should report a transition error")
  truthy(scheduler:forget("item"), "terminal items should be removable")
end

function tests.duplicate_item_error_survives_a_missing_canonical_object()
  local scheduler = Scheduler.new()
  scheduler:enqueue("item")
  scheduler.items.item = nil
  local duplicate, err = scheduler:enqueue("item")
  equal(duplicate, nil, "the retained scheduler metadata should still reject the duplicate ID")
  error_code(err, "duplicate_item", "the duplicate should return a structured error instead of crashing")
  equal(err.state, nil, "the error should tolerate a separately purged canonical object")
end

local order = {
  "queue_contains_ids_and_issues_one_lease",
  "external_registry_owns_the_canonical_lifecycle",
  "external_transition_failure_preserves_the_fifo",
  "work_item_store_integration_keeps_one_lifecycle",
  "starting_cancellation_waits_for_a_confirmed_turn",
  "preflight_deferral_blocks_and_requeues_in_fifo_order",
  "dispatched_or_running_work_cannot_be_deferred",
  "canonical_preflight_deferral_preserves_the_work_item",
  "restore_requirement_begins_only_when_policy_changes",
  "removed_cancelled_item_still_releases_its_late_turn",
  "early_turn_notifications_replay_after_binding",
  "failed_apply_returns_to_preview",
  "cancelled_early_completion_needs_no_interrupt",
  "retry_requeues_by_original_fifo_order_after_restore",
  "dead_retry_still_releases_after_restore",
  "failed_restore_blocks_but_releases_the_lease",
  "queued_cancellation_is_eager_and_does_not_touch_siblings",
  "running_cancellation_targets_only_the_owned_turn",
  "blocked_items_are_removed_and_can_be_requeued",
  "leased_blocked_item_cannot_be_unblocked",
  "clear_block_requeues_only_unleased_blocked_items",
  "invalid_transitions_return_structured_errors",
  "duplicate_item_error_survives_a_missing_canonical_object",
}

for _, name in ipairs(order) do
  tests[name]()
end

io.stdout:write(string.format("ok - %d scheduler tests\n", #order))
