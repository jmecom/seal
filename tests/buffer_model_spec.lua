local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local buffer_model = require("seal.buffer_model")

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

function tests.add_remove_and_context_share_one_snapshot()
  local lines = { "alpha", "beta", "gamma" }
  local model = buffer_model.new(lines)
  lines[2] = "caller mutation"
  model:add("first", {
    row = 1,
    column = 1,
    affinity = "right",
    selection = {
      start = { row = 0, column = 2 },
      finish = { row = 1, column = 2 },
    },
  })
  model:add("collocated", { row = 1, column = 1, affinity = "left" })
  local duplicate_ok = pcall(model.add, model, "first", { row = 0, column = 0 })

  equal(model:position("first").row, 1, "the point should retain its zero-based row")
  equal(model:position("collocated").row, 1, "collocated anchors should both be retained")
  truthy(not duplicate_ok, "an existing ID should require explicit resolve rather than silently losing ambiguity")
  equal(model:ids(), { "collocated", "first" }, "ids should provide a deterministic integration order")
  local snapshot = model:lines()
  snapshot[2] = "returned copy mutation"
  local context = model:context("first")
  equal(context.line, "beta", "context should read from the model's owned shared snapshot")
  equal(context.selection.text, "pha\nbe", "context should expose the selected bytes")
  truthy(model:remove("collocated"), "remove should report an existing anchor")
  equal(model:ids(), { "first" }, "remove should update the exposed ID list")
  truthy(model:position("collocated") == nil, "remove should delete only the requested anchor")
  truthy(model:position("first") ~= nil, "removing a collocated anchor must preserve its sibling")
end

function tests.same_text_whole_buffer_replacement_preserves_every_row()
  local model = buffer_model.new({ "same", "middle", "same" })
  model:add("top", { row = 0, column = 0 })
  model:add("middle", { row = 1, column = 2 })
  model:add("bottom", { row = 2, column = 0 })

  local original_diff = vim.diff
  local diff_calls = 0
  vim.diff = function(...)
    diff_calls = diff_calls + 1
    return original_diff(...)
  end
  local result = model:reconcile(0, 3, 3, { "same", "middle", "same" })
  vim.diff = original_diff

  equal(diff_calls, 0, "identical snapshots should not need a diff")
  equal(model:position("top").row, 0, "the first mark should not collapse")
  equal(model:position("middle").row, 1, "the middle mark should not collapse")
  equal(model:position("bottom").row, 2, "the final mark should not collapse")
  equal(result.ambiguous, {}, "identity replacement should be unambiguous")
end

function tests.one_diff_maps_all_anchors_and_selection()
  local model = buffer_model.new({ "alpha", "beta", "gamma" })
  model:add("alpha", { row = 0, column = 2 })
  model:add("gamma", { row = 2, column = 3 })
  model:add("selected", {
    row = 1,
    column = 0,
    selection = {
      start = { row = 1, column = 0 },
      finish = { row = 2, column = 5 },
    },
  })

  local original_diff = vim.diff
  local diff_calls = 0
  vim.diff = function(...)
    diff_calls = diff_calls + 1
    return original_diff(...)
  end
  model:reconcile(0, 3, 4, { "header", "alpha", "beta", "gamma" })
  vim.diff = original_diff

  equal(diff_calls, 1, "one reconciliation should compute at most one shared diff")
  equal(model:position("alpha").row, 1, "the first source line should follow the inserted header")
  equal(model:position("gamma").row, 3, "the last source line should follow the inserted header")
  local context = model:context("selected")
  equal(context.row, 2, "the selection's cursor should use the same row mapping")
  equal(context.selection.start.row, 2, "the selection start should follow the header")
  equal(context.selection.finish.row, 3, "the selection end should follow the header")
  equal(context.selection.text, "beta\ngamma", "the mapped selection should retain its text")
end

function tests.insertion_affinity_controls_only_the_boundary()
  local model = buffer_model.new({ "tail" })
  model:add("left", { row = 0, column = 0, affinity = "left" })
  model:add("right", { row = 0, column = 0, affinity = "right" })
  model:add("inside", { row = 0, column = 2, affinity = "left" })

  model:reconcile(0, 0, 1, { "inserted", "tail" })

  equal(model:position("left").row, 0, "left affinity should remain before inserted lines")
  equal(model:position("right").row, 1, "right affinity should follow inserted lines")
  equal(model:position("inside").row, 1, "a point inside the original line should follow that line")
  equal(model:position("inside").column, 2, "an unchanged line should preserve its byte column")
end

function tests.formatted_replacement_preserves_distinct_rows_and_marks_ambiguity()
  local model = buffer_model.new({ "a=1", "b=2", "c=3" })
  model:add("a", { row = 0, column = 1, affinity = "left" })
  model:add("b", { row = 1, column = 1, affinity = "right" })
  model:add("c", { row = 2, column = 1, affinity = "right" })

  local result = model:reconcile(0, 3, 3, { "a = 1", "b = 2", "c = 3" })

  equal(model:position("a").row, 0, "the first formatted line should retain its row")
  equal(model:position("b").row, 1, "the second formatted line should retain its row")
  equal(model:position("c").row, 2, "the third formatted line should retain its row")
  equal(result.ambiguous, { "a", "b", "c" }, "changed lines should report their non-unique correspondence")
  truthy(model:context("b").ambiguous, "context should expose mapping ambiguity")
end

function tests.deletion_collocates_without_dropping_anchors()
  local model = buffer_model.new({ "keep", "delete a", "delete b", "tail" })
  model:add("a", { row = 1, column = 2, affinity = "left" })
  model:add("b", { row = 2, column = 3, affinity = "right" })
  model:add("tail", { row = 3, column = 1 })

  local result = model:reconcile(1, 3, 1, { "keep", "tail" })

  equal(model:position("a").row, 1, "a deleted point should map to the deletion boundary")
  equal(model:position("b").row, 1, "multiple deleted points may intentionally collocate")
  truthy(model:position("a").ambiguity ~= nil, "a deleted point must be explicitly ambiguous")
  truthy(model:position("b").ambiguity ~= nil, "every deleted point must remain represented")
  equal(model:position("tail").row, 1, "an unchanged trailing line should map exactly")
  truthy(model:position("tail").ambiguity == nil, "an unchanged trailing line should remain unambiguous")
  equal(result.ambiguous, { "a", "b" }, "the result should identify every ambiguous item")
end

function tests.end_of_buffer_boundary_survives_replacement_and_insertion()
  local model = buffer_model.new({ "value" })
  model:add("eof-left", { row = 1, column = 0, affinity = "left" })
  model:add("eof-right", { row = 1, column = 0, affinity = "right" })

  model:reconcile(0, 1, 1, { "changed" })
  equal(model:position("eof-left").row, 1, "whole-buffer replacement should preserve the EOF boundary")
  equal(model:position("eof-right").row, 1, "EOF anchors should not clamp onto the final real line")

  model:reconcile(1, 1, 2, { "changed", "added" })
  equal(model:position("eof-left").row, 1, "left affinity should remain before an EOF insertion")
  equal(model:position("eof-right").row, 2, "right affinity should follow an EOF insertion")
end

function tests.ambiguity_persists_until_resolved_at_cursor()
  local model = buffer_model.new({ "old", "tail" })
  model:add("item", { row = 0, column = 1 })
  model:reconcile(0, 1, 1, { "new", "tail" })
  local original = model:position("item").ambiguity
  truthy(original ~= nil, "replacement should make the item ambiguous")

  model:reconcile(0, 0, 1, { "header", "new", "tail" })
  local pending = model:position("item")
  truthy(pending.ambiguity ~= nil, "later exact edits must not erase unresolved ambiguity")
  equal(pending.ambiguity.reason, original.reason, "the original ambiguity reason should remain available")
  equal(pending.ambiguity.revision, original.revision, "the ambiguity should retain its originating revision")
  equal(pending.ambiguity.current_revision, 2, "the ambiguity should track its current mapped revision")
  equal(pending.ambiguity.current, { row = pending.row, column = pending.column },
    "the ambiguity should track the deterministic current position")

  local cursor = { row = 2, column = 2, affinity = "right" }
  local resolved = model:resolve("item", cursor)
  equal({ resolved.row, resolved.column }, { cursor.row, cursor.column },
    "resolve should choose the supplied cursor exactly")
  truthy(resolved.ambiguity == nil, "only explicit resolution should clear point ambiguity")
  equal(model:resolve("item", cursor), resolved, "resolving repeatedly at the same cursor should be deterministic")
end

function tests.collocated_deleted_anchors_resolve_independently()
  local model = buffer_model.new({ "keep", "delete a", "delete b", "tail" })
  model:add("first", { row = 1, column = 3, affinity = "right" })
  model:add("second", { row = 2, column = 4, affinity = "right" })
  model:reconcile(1, 3, 1, { "keep", "tail" })

  equal(model:position("first").row, 1, "the first deleted anchor should map to the shared boundary")
  equal(model:position("second").row, 1, "the second deleted anchor should be allowed to collocate")
  truthy(model:position("first").ambiguity ~= nil, "the first deleted anchor should remain unresolved")
  truthy(model:position("second").ambiguity ~= nil, "the second deleted anchor should remain unresolved")

  local cursor = { row = 1, column = 2, affinity = "right" }
  local resolved = model:resolve("first", cursor)
  equal({ resolved.row, resolved.column }, { 1, 2 }, "the chosen item should resolve exactly at the cursor")
  truthy(resolved.ambiguity == nil, "the chosen item should no longer be ambiguous")
  truthy(model:position("second").ambiguity ~= nil, "resolving one collocated item must not resolve its sibling")
  equal(model:ids(), { "first", "second" }, "resolution must not add, remove, or reorder collocated IDs")

  model:reconcile(0, 0, 1, { "header", "keep", "tail" })
  local moved_first = model:position("first")
  local moved_second = model:position("second")
  equal({ moved_first.row, moved_first.column }, { 2, 2 },
    "the resolved cursor should map deterministically through later edits")
  truthy(moved_first.ambiguity == nil, "an exact later edit should keep the resolved item exact")
  equal(moved_second.ambiguity.current, { row = moved_second.row, column = moved_second.column },
    "the unresolved sibling should retain and update its explicit ambiguity")
end

function tests.later_deletion_is_not_hidden_by_older_ambiguity()
  local model = buffer_model.new({ "old", "tail" })
  model:add("item", { row = 0, column = 1, affinity = "right" })
  model:reconcile(0, 1, 1, { "new", "tail" })
  equal(model:position("item").ambiguity.reason, "line-replaced",
    "the first replacement should record its ambiguity")

  model:reconcile(0, 1, 0, { "tail" })
  local pending = model:position("item").ambiguity
  equal(pending.origin_reason, "line-replaced", "the original ambiguity should remain auditable")
  equal(pending.reason, "line-deleted", "a later deletion should become the actionable ambiguity")
  equal(pending.latest.reason, "line-deleted", "the latest ambiguity should carry deletion candidates")
  equal(pending.current, { row = 0, column = 0 }, "the deleted anchor should retain a deterministic boundary")
end

function tests.resolve_and_set_selection_are_independent()
  local model = buffer_model.new({ "old value", "tail" })
  model:add("item", {
    row = 0,
    column = 4,
    affinity = "right",
    selection = {
      start = { row = 0, column = 0 },
      finish = { row = 0, column = 3 },
    },
  })
  model:reconcile(0, 1, 1, { "new value", "tail" })
  truthy(model:context("item").ambiguous, "the replacement should make the item unresolved")

  local resolved = model:resolve("item")
  truthy(resolved.ambiguity == nil, "resolve without a point should clear point ambiguity")
  truthy(resolved.selection ~= nil, "resolve without a point should preserve selection")
  truthy(
    resolved.selection.start.ambiguity == nil and resolved.selection.finish.ambiguity == nil,
    "resolve should clear preserved selection ambiguity"
  )

  local moved = model:resolve("item", { row = 1, column = 2 })
  equal({ moved.row, moved.column }, { 1, 2 }, "resolve should accept a replacement point")
  truthy(moved.selection ~= nil, "a replacement point should preserve selection when it is omitted")

  model:reconcile(1, 2, 2, { "new value", "TAIL" })
  local point_ambiguity = model:position("item").ambiguity
  truthy(point_ambiguity ~= nil, "the second replacement should make the point ambiguous again")
  local selected = model:set_selection("item", {
    start = { row = 1, column = 0 },
    finish = { row = 1, column = 4 },
  })
  equal(selected.selection.start.row, 1, "set_selection should replace visual context")
  equal(selected.ambiguity, point_ambiguity, "set_selection must not resolve the insertion point")
  truthy(model:set_selection("item", nil).selection == nil, "set_selection(nil) should drop visual context")

  local replaced = model:resolve("item", {
    row = 0,
    column = 0,
    selection = {
      start = { row = 0, column = 0 },
      finish = { row = 0, column = 3 },
    },
  })
  equal(replaced.selection.finish.column, 3, "resolve should optionally replace selection")
  truthy(model:resolve("item", { row = 0, column = 0, selection = false }).selection == nil,
    "resolve should explicitly clear selection")
end

function tests.selection_ambiguity_persists_until_item_resolution()
  local model = buffer_model.new({ "selected text", "stable cursor" })
  model:add("item", {
    row = 1,
    column = 3,
    selection = {
      start = { row = 0, column = 0 },
      finish = { row = 0, column = #"selected text" },
    },
  })

  model:reconcile(0, 1, 1, { "changed selection", "stable cursor" })
  local position = model:position("item")
  truthy(position.ambiguity == nil, "an unchanged cursor line should remain exact")
  truthy(position.selection.start.ambiguity ~= nil, "the changed selection start should be explicit")
  truthy(position.selection.finish.ambiguity ~= nil, "the changed selection finish should be explicit")
  truthy(model:context("item").ambiguous, "selection ambiguity should make the whole context unresolved")

  model:reconcile(0, 0, 1, { "header", "changed selection", "stable cursor" })
  local pending = model:position("item")
  truthy(pending.selection.start.ambiguity ~= nil, "an exact later edit must not erase selection ambiguity")
  equal(
    pending.selection.start.ambiguity.current,
    { row = pending.selection.start.row, column = pending.selection.start.column },
    "selection ambiguity should track its deterministic current endpoint"
  )

  local resolved = model:resolve("item", { row = 2, column = 3 })
  truthy(resolved.selection ~= nil, "resolving at the cursor should preserve selection by default")
  truthy(
    resolved.selection.start.ambiguity == nil and resolved.selection.finish.ambiguity == nil,
    "explicit item resolution should clear preserved selection ambiguity"
  )
  truthy(not model:context("item").ambiguous, "resolved point and selection context should be exact")
end

function tests.selection_expands_with_a_formatted_source_line()
  local model = buffer_model.new({ "local compact=true", "return compact" })
  model:add("item", {
    row = 0,
    column = 0,
    selection = {
      start = { row = 0, column = 0 },
      finish = { row = 0, column = #"local compact=true" },
    },
  })

  model:reconcile(0, 1, 3, {
    "local compact = {",
    "  enabled = true,",
    "}",
    "return compact",
  })

  local selection = model:context("item").selection
  equal(selection.start.row, 0, "the selection should retain the first replacement line")
  equal(selection.finish.row, 2, "the selection should expand through the final replacement line")
  equal(selection.text, "local compact = {\n  enabled = true,\n}",
    "the expanded selection should not absorb the following unchanged line")
end

function tests.changed_slice_reconciles_many_anchors_without_diff()
  local lines = {}
  for index = 1, 10000 do
    lines[index] = "line " .. index
  end
  local model = buffer_model.new(lines)
  for index = 1, 100 do
    model:add(index, { row = index * 90, column = 2, affinity = "right" })
  end
  local original_diff = vim.diff
  local diff_calls = 0
  vim.diff = function(...)
    diff_calls = diff_calls + 1
    return original_diff(...)
  end
  model:reconcile_edit(10, 10, { "inserted" })
  vim.diff = original_diff

  equal(diff_calls, 0, "ordinary changed-slice reconciliation should never invoke vim.diff")
  equal(model:position(1).row, 91, "an anchor below the insertion should shift once")
  equal(model:position(100).row, 9001, "the final anchor should use the same shared delta")
  equal(model:lines()[11], "inserted", "the shared snapshot should splice in the changed slice")
end

function tests.changed_slice_splices_every_buffer_boundary()
  local cases = {
    {
      name = "insert at start",
      lines = { "a", "b", "c" },
      first = 0,
      last = 0,
      replacement = { "x", "y" },
      expected = { "x", "y", "a", "b", "c" },
    },
    {
      name = "insert at end",
      lines = { "a", "b", "c" },
      first = 3,
      last = 3,
      replacement = { "x" },
      expected = { "a", "b", "c", "x" },
    },
    {
      name = "delete at start",
      lines = { "a", "b", "c" },
      first = 0,
      last = 1,
      replacement = {},
      expected = { "b", "c" },
    },
    {
      name = "delete in middle",
      lines = { "a", "b", "c" },
      first = 1,
      last = 2,
      replacement = {},
      expected = { "a", "c" },
    },
    {
      name = "delete at end",
      lines = { "a", "b", "c" },
      first = 2,
      last = 3,
      replacement = {},
      expected = { "a", "b" },
    },
    {
      name = "grow replacement",
      lines = { "a", "b", "c" },
      first = 1,
      last = 2,
      replacement = { "x", "y", "z" },
      expected = { "a", "x", "y", "z", "c" },
    },
    {
      name = "shrink replacement",
      lines = { "a", "b", "c", "d" },
      first = 1,
      last = 3,
      replacement = { "x" },
      expected = { "a", "x", "d" },
    },
    {
      name = "replace whole buffer",
      lines = { "a", "b", "c" },
      first = 0,
      last = 3,
      replacement = { "x", "y" },
      expected = { "x", "y" },
    },
  }

  for _, case in ipairs(cases) do
    local model = buffer_model.new(case.lines)
    model:add("eof", { row = #case.lines, column = 0, affinity = "right" })
    model:reconcile_edit(case.first, case.last, case.replacement)
    equal(model:lines(), case.expected, case.name .. " should splice the shared snapshot exactly")
    equal(model:position("eof").row, #case.expected, case.name .. " should map the EOF boundary once")
  end
end

function tests.changed_slice_preserves_unchanged_duplicate_rows()
  local model = buffer_model.new({ "same", "same", "old" })
  model:add("first", { row = 0, column = 2 })
  model:add("second", { row = 1, column = 3 })
  model:add("changed", { row = 2, column = 1 })

  local result = model:reconcile_edit(0, 3, { "same", "same", "new" })

  truthy(model:position("first").ambiguity == nil,
    "an unchanged duplicate should retain its exact row within an equal-sized replacement")
  truthy(model:position("second").ambiguity == nil,
    "each unchanged duplicate should retain its own exact row")
  equal(result.ambiguous, { "changed" }, "only the actually replaced row should need confirmation")
end

function tests.changed_slice_does_not_collapse_old_duplicates_exactly()
  local model = buffer_model.new({ "same", "same", "tail" })
  model:add("first", { row = 0, column = 2 })
  model:add("second", { row = 1, column = 3 })

  local result = model:reconcile_edit(0, 2, { "same" })

  equal(model:lines(), { "same", "tail" }, "the replacement should retain the single surviving line")
  equal(result.ambiguous, { "first", "second" },
    "neither old duplicate can be identified as the unique survivor")
  truthy(model:position("first").ambiguity ~= nil and model:position("second").ambiguity ~= nil,
    "both collocated anchors should require explicit resolution")
end

function tests.equal_sized_edit_does_not_copy_the_buffer_tail()
  local lines = {}
  for index = 1, 1000 do
    lines[index] = "line " .. index
  end
  local model = buffer_model.new(lines)
  local original_move = table.move
  local move_calls = 0
  table.move = function(...)
    move_calls = move_calls + 1
    return original_move(...)
  end
  local ok, err = pcall(model.reconcile_edit, model, 10, 11, { "edited line" })
  table.move = original_move
  truthy(ok, "the equal-sized edit should reconcile: " .. tostring(err))

  equal(move_calls, 0, "an edit with no line-count delta should not copy the unchanged buffer tail")
  equal(model:lines()[11], "edited line", "the changed line should still update in place")
  equal(model:lines()[1000], "line 1000", "skipping the tail copy must preserve later lines")
end

function tests.context_can_skip_large_selection_text()
  local model = buffer_model.new({ "alpha", "beta", "gamma" })
  model:add("selection", {
    row = 0,
    column = 0,
    selection = {
      start = { row = 0, column = 0 },
      finish = { row = 2, column = 5 },
    },
  })
  local context = model:context("selection", { include_selection_text = false })
  truthy(context.selection ~= nil, "selection bounds should remain available")
  equal(context.selection.text, nil, "hot-path reconciliation should not materialize selection text")
  equal(model:context("selection").selection.text, "alpha\nbeta\ngamma",
    "prompt capture should still materialize selection text on demand")
end

local order = {
  "add_remove_and_context_share_one_snapshot",
  "same_text_whole_buffer_replacement_preserves_every_row",
  "one_diff_maps_all_anchors_and_selection",
  "insertion_affinity_controls_only_the_boundary",
  "formatted_replacement_preserves_distinct_rows_and_marks_ambiguity",
  "deletion_collocates_without_dropping_anchors",
  "end_of_buffer_boundary_survives_replacement_and_insertion",
  "ambiguity_persists_until_resolved_at_cursor",
  "collocated_deleted_anchors_resolve_independently",
  "later_deletion_is_not_hidden_by_older_ambiguity",
  "resolve_and_set_selection_are_independent",
  "selection_ambiguity_persists_until_item_resolution",
  "selection_expands_with_a_formatted_source_line",
  "changed_slice_reconciles_many_anchors_without_diff",
  "changed_slice_splices_every_buffer_boundary",
  "changed_slice_preserves_unchanged_duplicate_rows",
  "changed_slice_does_not_collapse_old_duplicates_exactly",
  "equal_sized_edit_does_not_copy_the_buffer_tail",
  "context_can_skip_large_selection_text",
}

for _, name in ipairs(order) do
  tests[name]()
  io.stdout:write("ok - " .. name .. "\n")
end

io.stdout:write(string.format("%d tests passed\n", #order))
