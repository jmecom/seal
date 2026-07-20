local M = {}

local Model = {}
Model.__index = Model

-- Invariants:
--   * One Model represents one buffer and owns one line snapshot per revision.
--     Anchors never retain private copies of the buffer.
--   * Rows are zero-based. Columns are byte offsets. Row #lines is the valid
--     end-of-buffer insertion boundary.
--   * Reconciliation maps every anchor from the same old snapshot to the same
--     new snapshot. It calls vim.diff no more than once.
--   * Mapping never removes an anchor. When changed text has no unique
--     correspondence, the model keeps a deterministic position and records an
--     ambiguity until that item is explicitly removed or resolved.

local function copy_lines(lines)
  assert(type(lines) == "table", "lines must be a list")
  local result = {}
  for index, line in ipairs(lines) do
    assert(type(line) == "string", "every buffer line must be a string")
    result[index] = line
  end
  assert(#result > 0, "a buffer snapshot must contain at least one line")
  return result
end

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy_value(child)
  end
  return result
end

local function id_less(left, right)
  local left_type = type(left)
  local right_type = type(right)
  if left_type ~= right_type then
    return left_type < right_type
  end
  if left_type == "number" or left_type == "string" then
    return left < right
  end
  return tostring(left) < tostring(right)
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if right[index] ~= line then
      return false
    end
  end
  return true
end

local function check_integer(value, name)
  assert(type(value) == "number" and value >= 0 and value % 1 == 0, name .. " must be a non-negative integer")
end

local function normalize_affinity(affinity)
  affinity = affinity or "right"
  assert(affinity == "left" or affinity == "right", "affinity must be 'left' or 'right'")
  return affinity
end

local function line_at(lines, row)
  return row < #lines and lines[row + 1] or ""
end

local function normalize_point(lines, point, default_affinity)
  assert(type(point) == "table", "anchor point must be a table")
  check_integer(point.row, "row")
  check_integer(point.column or 0, "column")
  assert(point.row <= #lines, "row is outside the buffer snapshot")
  local line = line_at(lines, point.row)
  return {
    row = point.row,
    column = math.min(point.column or 0, #line),
    affinity = normalize_affinity(point.affinity or default_affinity),
  }
end

local function point_before(left, right)
  return left.row < right.row or (left.row == right.row and left.column <= right.column)
end

local function normalize_selection(lines, selection)
  if selection == nil then
    return nil
  end
  assert(type(selection) == "table", "selection must be a table")
  local first = normalize_point(lines, selection.start, "left")
  local last = normalize_point(lines, selection.finish, "right")
  if not point_before(first, last) then
    first, last = last, first
    first.affinity = "left"
    last.affinity = "right"
  end
  first.selection_edge = "start"
  last.selection_edge = "finish"
  return { start = first, finish = last }
end

local function common_edges(old_line, new_line)
  local prefix_limit = math.min(#old_line, #new_line)
  local prefix = 0
  while prefix < prefix_limit and old_line:byte(prefix + 1) == new_line:byte(prefix + 1) do
    prefix = prefix + 1
  end

  local suffix_limit = math.min(#old_line - prefix, #new_line - prefix)
  local suffix = 0
  while suffix < suffix_limit
    and old_line:byte(#old_line - suffix) == new_line:byte(#new_line - suffix)
  do
    suffix = suffix + 1
  end
  return prefix, suffix
end

local function map_column(old_line, new_line, column, affinity)
  column = math.min(column, #old_line)
  if old_line == new_line then
    return math.min(column, #new_line), nil
  end

  local prefix, suffix = common_edges(old_line, new_line)
  if column <= prefix then
    return column, nil
  end
  if column >= #old_line - suffix then
    return math.max(0, #new_line - (#old_line - column)), nil
  end

  local left = prefix
  local right = #new_line - suffix
  return affinity == "left" and left or right, {
    reason = "column-replaced",
    candidates = {
      { column = left },
      { column = right },
    },
  }
end

local function direct_row_entry(old_row, first, last, new_last)
  local delta = new_last - last
  if old_row < first then
    return { left = old_row, right = old_row, exact = true }
  end
  if old_row >= last then
    local row = old_row + delta
    return { left = row, right = row, exact = true }
  end
  return {
    left = first,
    right = new_last,
    exact = false,
    reason = last == new_last and "line-replaced" or "range-replaced",
  }
end

local function hunk_start(start, count)
  return count == 0 and start or start - 1
end

local function replacement_entry(
  old_lines,
  old_row,
  old_start,
  old_count,
  new_start,
  new_count,
  new_rows_by_text,
  old_counts_by_text
)
  if new_count == 0 then
    return {
      left = new_start,
      right = new_start,
      exact = false,
      reason = "line-deleted",
    }
  end

  local old_line = old_lines[old_row + 1]
  local matches = new_rows_by_text[old_line] or {}
  local old_matches = old_counts_by_text and old_counts_by_text[old_line] or 1
  if #matches == 1 and old_matches == 1 then
    return { left = matches[1], right = matches[1], exact = true }
  end
  if #matches > 0 then
    return {
      left = matches[1],
      right = matches[#matches],
      exact = false,
      reason = "duplicate-line",
      candidate_rows = matches,
    }
  end

  local relative = old_row - old_start
  local left_offset = math.floor(relative * new_count / old_count)
  local right_offset = math.ceil((relative + 1) * new_count / old_count) - 1
  left_offset = math.max(0, math.min(left_offset, new_count - 1))
  right_offset = math.max(left_offset, math.min(right_offset, new_count - 1))
  return {
    left = new_start + left_offset,
    right = new_start + right_offset,
    exact = false,
    reason = "line-replaced",
  }
end

local function build_direct_plan(old_lines, new_lines, first, last, new_last)
  local plan = {}
  local old_count = last - first
  local new_count = new_last - first
  local new_rows_by_text = {}
  local old_counts_by_text = {}
  for row = first, last - 1 do
    local line = old_lines[row + 1]
    old_counts_by_text[line] = (old_counts_by_text[line] or 0) + 1
  end
  for row = first, new_last - 1 do
    local line = new_lines[row + 1]
    new_rows_by_text[line] = new_rows_by_text[line] or {}
    table.insert(new_rows_by_text[line], row)
  end
  for row = 0, #old_lines - 1 do
    if row < first or row >= last then
      plan[row] = direct_row_entry(row, first, last, new_last)
    elseif old_count > 0 then
      local offset = row - first + 1
      if old_count == new_count and old_lines[row + 1] == new_lines[first + offset] then
        plan[row] = { left = row, right = row, exact = true }
      else
        plan[row] = replacement_entry(
          old_lines,
          row,
          first,
          old_count,
          first,
          new_count,
          new_rows_by_text,
          old_counts_by_text
        )
      end
    end
  end
  return plan
end

local function build_row_plan(old_lines, new_lines, first, last, new_last, opts)
  local plan = {}
  if same_lines(old_lines, new_lines) then
    for row = 0, #old_lines - 1 do
      plan[row] = { left = row, right = row, exact = true }
    end
    return plan
  end

  if opts and opts.direct then
    return build_direct_plan(old_lines, new_lines, first, last, new_last)
  end

  local ok, hunks = pcall(vim.diff, table.concat(old_lines, "\n") .. "\n", table.concat(new_lines, "\n") .. "\n", {
    result_type = "indices",
    algorithm = "histogram",
    linematch = 1000,
  })
  if not ok or type(hunks) ~= "table" then
    for row = 0, #old_lines - 1 do
      plan[row] = direct_row_entry(row, first, last, new_last)
    end
    return plan
  end

  local old_cursor = 0
  local new_cursor = 0
  for _, hunk in ipairs(hunks) do
    local old_start_raw, old_count, new_start_raw, new_count = unpack(hunk)
    local old_start = hunk_start(old_start_raw, old_count)
    local new_start = hunk_start(new_start_raw, new_count)

    local unchanged = math.min(old_start - old_cursor, new_start - new_cursor)
    for offset = 0, unchanged - 1 do
      plan[old_cursor + offset] = {
        left = new_cursor + offset,
        right = new_cursor + offset,
        exact = true,
      }
    end

    local new_rows_by_text = {}
    local old_counts_by_text = {}
    for row = old_start, old_start + old_count - 1 do
      local line = old_lines[row + 1]
      old_counts_by_text[line] = (old_counts_by_text[line] or 0) + 1
    end
    for row = new_start, new_start + new_count - 1 do
      local line = new_lines[row + 1]
      new_rows_by_text[line] = new_rows_by_text[line] or {}
      table.insert(new_rows_by_text[line], row)
    end
    for row = old_start, old_start + old_count - 1 do
      plan[row] = replacement_entry(
        old_lines,
        row,
        old_start,
        old_count,
        new_start,
        new_count,
        new_rows_by_text,
        old_counts_by_text
      )
    end
    old_cursor = old_start + old_count
    new_cursor = new_start + new_count
  end

  while old_cursor < #old_lines and new_cursor < #new_lines do
    plan[old_cursor] = { left = new_cursor, right = new_cursor, exact = true }
    old_cursor = old_cursor + 1
    new_cursor = new_cursor + 1
  end
  for row = old_cursor, #old_lines - 1 do
    plan[row] = direct_row_entry(row, first, last, new_last)
  end
  return plan
end

-- `revision`, `previous`, and `candidates` describe where ambiguity began.
-- `reason` is the latest actionable reason, while `current` follows the
-- deterministic fallback through later edits until resolve clears the record.
local function ambiguity(reason, revision, old_point, candidates)
  local unique = {}
  local result = {}
  for _, candidate in ipairs(candidates) do
    local key = candidate.row .. ":" .. candidate.column
    if not unique[key] then
      unique[key] = true
      table.insert(result, candidate)
    end
  end
  return {
    reason = reason,
    origin_reason = reason,
    revision = revision,
    previous = { row = old_point.row, column = old_point.column },
    candidates = result,
  }
end

local function retain_ambiguity(point, previous, revision)
  if previous then
    previous.current = { row = point.row, column = point.column }
    previous.current_revision = revision
  end
  point.ambiguity = previous
end

local function map_point_with(point, old_lines, new_line_count, new_line_at, entry_for_row, event, revision)
  local old_point = { row = point.row, column = point.column }
  local previous_ambiguity = point.ambiguity

  if point.row == #old_lines then
    if event.first == event.last and point.row == event.first and point.affinity == "left" then
      point.row = event.first
    else
      point.row = new_line_count
    end
    point.column = 0
    retain_ambiguity(point, previous_ambiguity, revision)
    return
  end

  if event.first == event.last
    and point.row == event.first
    and point.column == 0
    and point.affinity == "left"
  then
    point.row = event.first
    point.column = 0
    retain_ambiguity(point, previous_ambiguity, revision)
    return
  end

  local entry = entry_for_row(point.row)
    or direct_row_entry(point.row, event.first, event.last, event.new_last)
  local chosen_row = point.affinity == "left" and entry.left or entry.right
  local old_line = line_at(old_lines, point.row)
  if point.selection_edge == "start"
    and point.row == event.first
    and old_point.column == 0
  then
    chosen_row = event.first
  elseif point.selection_edge == "finish"
    and point.row == event.last - 1
    and old_point.column >= #old_line
    and event.new_last > event.first
  then
    chosen_row = event.new_last - 1
  end
  chosen_row = math.max(0, math.min(chosen_row, new_line_count))

  local new_line = new_line_at(chosen_row)
  local chosen_column, column_ambiguity = map_column(old_line, new_line, point.column, point.affinity)
  if chosen_row == new_line_count or entry.reason == "line-deleted" then
    chosen_column = 0
  end

  point.row = chosen_row
  point.column = chosen_column
  local reason = not entry.exact and entry.reason or column_ambiguity and column_ambiguity.reason
  if not reason then
    retain_ambiguity(point, previous_ambiguity, revision)
    return
  end

  local candidate_rows = entry.candidate_rows or { entry.left, entry.right }
  local candidates = {}
  for _, row in ipairs(candidate_rows) do
    row = math.max(0, math.min(row, new_line_count))
    local candidate_line = new_line_at(row)
    local column = map_column(old_line, candidate_line, old_point.column, point.affinity)
    if row == new_line_count or entry.reason == "line-deleted" then
      column = 0
    end
    table.insert(candidates, { row = row, column = column })
  end
  if column_ambiguity and entry.exact then
    candidates = {
      { row = chosen_row, column = column_ambiguity.candidates[1].column },
      { row = chosen_row, column = column_ambiguity.candidates[2].column },
    }
  end
  local current_ambiguity = ambiguity(reason, revision, old_point, candidates)
  current_ambiguity.current = { row = point.row, column = point.column }
  current_ambiguity.current_revision = revision
  if previous_ambiguity then
    previous_ambiguity.reason = reason
    previous_ambiguity.latest = current_ambiguity
    retain_ambiguity(point, previous_ambiguity, revision)
  else
    point.ambiguity = current_ambiguity
  end
end

local function map_point(point, old_lines, new_lines, row_plan, event, revision)
  return map_point_with(
    point,
    old_lines,
    #new_lines,
    function(row)
      return line_at(new_lines, row)
    end,
    function(row)
      return row_plan[row]
    end,
    event,
    revision
  )
end

local function selected_text(lines, selection)
  if not selection then
    return nil
  end
  local first = selection.start
  local last = selection.finish
  if first.row == last.row then
    return line_at(lines, first.row):sub(first.column + 1, last.column)
  end

  local parts = { line_at(lines, first.row):sub(first.column + 1) }
  for row = first.row + 1, last.row - 1 do
    table.insert(parts, line_at(lines, row))
  end
  table.insert(parts, line_at(lines, last.row):sub(1, last.column))
  return table.concat(parts, "\n")
end

function M.new(lines)
  return setmetatable({
    _lines = copy_lines(lines),
    _anchors = {},
    revision = 0,
  }, Model)
end

function Model:lines()
  return copy_lines(self._lines)
end

function Model:ids()
  local ids = {}
  for id in pairs(self._anchors) do
    table.insert(ids, id)
  end
  table.sort(ids, id_less)
  return ids
end

-- anchor is { row, column, affinity?, selection? }. A selection is
-- { start = point, finish = point }; its finish is exclusive. IDs are unique
-- within a model; use resolve to reposition an existing anchor.
function Model:add(id, anchor)
  assert(id ~= nil, "anchor id is required")
  assert(self._anchors[id] == nil, "anchor id already exists; use resolve to reposition it")
  local point = normalize_point(self._lines, anchor)
  point.selection = normalize_selection(self._lines, anchor.selection)
  self._anchors[id] = point
  return self:position(id)
end

function Model:remove(id)
  local existed = self._anchors[id] ~= nil
  self._anchors[id] = nil
  return existed
end

-- Replaces or clears the optional selection without changing the point or its
-- ambiguity. This is useful when an editor edit makes visual context stale but
-- leaves the insertion point meaningful.
function Model:set_selection(id, selection)
  local anchor = self._anchors[id]
  if not anchor then
    return nil
  end
  anchor.selection = normalize_selection(self._lines, selection)
  return self:position(id)
end

local function clear_point_ambiguity(point)
  point.ambiguity = nil
end

-- Clears an item's unresolved mapping. With no point, the current point and
-- selection are preserved. A replacement point may omit selection to preserve
-- it, provide a selection table to replace it, or use selection=false to drop
-- it explicitly.
function Model:resolve(id, point)
  local anchor = self._anchors[id]
  if not anchor then
    return nil
  end

  if point then
    local selection = anchor.selection
    local replacement = normalize_point(self._lines, {
      row = point.row,
      column = point.column,
      affinity = point.affinity or anchor.affinity,
    })
    if point.selection == false then
      selection = nil
    elseif point.selection ~= nil then
      selection = normalize_selection(self._lines, point.selection)
    end
    replacement.selection = selection
    self._anchors[id] = replacement
    anchor = replacement
  end

  clear_point_ambiguity(anchor)
  if anchor.selection then
    clear_point_ambiguity(anchor.selection.start)
    clear_point_ambiguity(anchor.selection.finish)
  end
  return self:position(id)
end

-- Moves an anchor after a controlled editor operation without treating that
-- operation as the user's explicit ambiguity resolution. Any existing point
-- or selection ambiguity is promoted to the moved point and remains sticky.
function Model:relocate(id, point)
  local anchor = self._anchors[id]
  if not anchor or not point then
    return nil
  end
  local preserved = anchor.ambiguity
    or anchor.selection
      and (anchor.selection.start.ambiguity or anchor.selection.finish.ambiguity)
  local replacement = normalize_point(self._lines, {
    row = point.row,
    column = point.column,
    affinity = point.affinity or anchor.affinity,
  })
  if point.selection == false then
    replacement.selection = nil
  elseif point.selection ~= nil then
    replacement.selection = normalize_selection(self._lines, point.selection)
  else
    replacement.selection = anchor.selection
  end
  if preserved then
    preserved.current = { row = replacement.row, column = replacement.column }
    preserved.current_revision = self.revision
    replacement.ambiguity = preserved
  end
  self._anchors[id] = replacement
  return self:position(id)
end

function Model:position(id)
  local anchor = self._anchors[id]
  return anchor and copy_value(anchor) or nil
end

function Model:context(id, opts)
  local anchor = self._anchors[id]
  if not anchor then
    return nil
  end
  local position = self:position(id)
  opts = opts or {}
  local include_selection_text = opts.include_selection_text ~= false
  return {
    revision = self.revision,
    row = position.row,
    column = position.column,
    line = line_at(self._lines, position.row),
    selection = position.selection and {
      start = position.selection.start,
      finish = position.selection.finish,
      text = include_selection_text and selected_text(self._lines, position.selection) or nil,
    } or nil,
    ambiguous = position.ambiguity ~= nil
      or position.selection ~= nil
        and (position.selection.start.ambiguity ~= nil or position.selection.finish.ambiguity ~= nil)
      or false,
    ambiguity = position.ambiguity,
  }
end

local function finish_selection(anchor)
  if anchor.selection and not point_before(anchor.selection.start, anchor.selection.finish) then
    anchor.selection.start, anchor.selection.finish = anchor.selection.finish, anchor.selection.start
    anchor.selection.start.affinity = "left"
    anchor.selection.finish.affinity = "right"
    anchor.selection.start.selection_edge = "start"
    anchor.selection.finish.selection_edge = "finish"
  end
end

local function anchor_is_ambiguous(anchor)
  return anchor.ambiguity
    or anchor.selection
      and (anchor.selection.start.ambiguity or anchor.selection.finish.ambiguity)
end

-- Fast path for ordinary on_lines events. The caller supplies only the
-- changed post-edit slice. Anchor mapping touches each anchor once, does not
-- call vim.diff, and updates the shared line snapshot in place.
function Model:reconcile_edit(first, last, replacement)
  check_integer(first, "first")
  check_integer(last, "last")
  assert(first <= last and last <= #self._lines, "old on_lines range is outside the snapshot")
  assert(type(replacement) == "table", "replacement lines must be a list")
  local new_lines = {}
  for index, line in ipairs(replacement) do
    assert(type(line) == "string", "every replacement line must be a string")
    new_lines[index] = line
  end

  local old_lines = self._lines
  local old_length = #old_lines
  local old_count = last - first
  local new_count = #new_lines
  local new_last = first + new_count
  local new_length = old_length - old_count + new_count
  assert(new_length > 0, "a buffer snapshot must contain at least one line")
  local delta = new_count - old_count
  local event = { first = first, last = last, new_last = new_last }
  local identical = old_count == new_count
  if identical then
    for offset = 1, old_count do
      if old_lines[first + offset] ~= new_lines[offset] then
        identical = false
        break
      end
    end
  end
  local rows_by_text = {}
  local old_counts_by_text = {}
  for row = first, last - 1 do
    local line = old_lines[row + 1]
    old_counts_by_text[line] = (old_counts_by_text[line] or 0) + 1
  end
  for offset, line in ipairs(new_lines) do
    rows_by_text[line] = rows_by_text[line] or {}
    table.insert(rows_by_text[line], first + offset - 1)
  end
  local function entry_for_row(row)
    if identical and row >= first and row < last then
      return { left = row, right = row, exact = true }
    end
    if row < first or row >= last then
      return direct_row_entry(row, first, last, new_last)
    end
    local offset = row - first + 1
    if old_count == new_count and old_lines[row + 1] == new_lines[offset] then
      return { left = row, right = row, exact = true }
    end
    return replacement_entry(
      old_lines,
      row,
      first,
      old_count,
      first,
      new_count,
      rows_by_text,
      old_counts_by_text
    )
  end
  local function new_line_at(row)
    if row >= new_length then
      return ""
    end
    if row < first then
      return old_lines[row + 1]
    end
    if row < new_last then
      return new_lines[row - first + 1]
    end
    return old_lines[row - delta + 1]
  end

  self.revision = self.revision + 1
  local ambiguous_ids = {}
  for id, anchor in pairs(self._anchors) do
    map_point_with(anchor, old_lines, new_length, new_line_at, entry_for_row, event, self.revision)
    if anchor.selection then
      map_point_with(anchor.selection.start, old_lines, new_length, new_line_at, entry_for_row, event, self.revision)
      map_point_with(anchor.selection.finish, old_lines, new_length, new_line_at, entry_for_row, event, self.revision)
      finish_selection(anchor)
    end
    if anchor_is_ambiguous(anchor) then
      table.insert(ambiguous_ids, id)
    end
  end

  if table.move then
    if delta ~= 0 and last < old_length then
      table.move(old_lines, last + 1, old_length, new_last + 1, old_lines)
    end
    for index = new_length + 1, old_length do
      old_lines[index] = nil
    end
    for index, line in ipairs(new_lines) do
      old_lines[first + index] = line
    end
  else
    local rebuilt = {}
    for index = 1, first do
      rebuilt[index] = old_lines[index]
    end
    for index, line in ipairs(new_lines) do
      rebuilt[first + index] = line
    end
    for index = last + 1, old_length do
      rebuilt[index + delta] = old_lines[index]
    end
    self._lines = rebuilt
  end

  table.sort(ambiguous_ids, id_less)
  return { revision = self.revision, ambiguous = ambiguous_ids }
end

-- first, last, and new_last mirror nvim_buf_attach's on_lines indices. The
-- caller supplies the complete post-edit line snapshot so all anchors are
-- reconciled together rather than consulting independently mutated extmarks.
function Model:reconcile(first, last, new_last, lines, opts)
  check_integer(first, "first")
  check_integer(last, "last")
  check_integer(new_last, "new_last")
  assert(first <= last and last <= #self._lines, "old on_lines range is outside the snapshot")
  local new_lines = copy_lines(lines)
  assert(first <= new_last and new_last <= #new_lines, "new on_lines range is outside the snapshot")
  assert(
    #new_lines == #self._lines - (last - first) + (new_last - first),
    "on_lines range does not match the supplied snapshot"
  )

  local old_lines = self._lines
  local row_plan = build_row_plan(old_lines, new_lines, first, last, new_last, opts)
  self.revision = self.revision + 1
  local event = { first = first, last = last, new_last = new_last }
  local ambiguous_ids = {}

  for id, anchor in pairs(self._anchors) do
    map_point(anchor, old_lines, new_lines, row_plan, event, self.revision)
    if anchor.selection then
      map_point(anchor.selection.start, old_lines, new_lines, row_plan, event, self.revision)
      map_point(anchor.selection.finish, old_lines, new_lines, row_plan, event, self.revision)
      finish_selection(anchor)
    end
    if anchor_is_ambiguous(anchor) then
      table.insert(ambiguous_ids, id)
    end
  end
  self._lines = new_lines

  table.sort(ambiguous_ids, id_less)
  return { revision = self.revision, ambiguous = ambiguous_ids }
end

return M
