local anchor = require("contextmark.anchor")
local config = require("contextmark.config")
local identity = require("contextmark.identity")
local store = require("contextmark.store")
local util = require("contextmark.util")

local M = {}
local namespace = vim.api.nvim_create_namespace("contextmark")
local marks = {}

local function buffer_context(bufnr)
  return util.buffer_context(bufnr)
end

-- Highest-severity status wins when several notes share a line.
local severity_rank = { ok = 0, stale = 1, mismatch = 2 }

local function severity_of(status)
  if status == "mismatch" then
    return "mismatch"
  end
  return util.is_warning_status(status) and "stale" or "ok"
end

-- What a note's status becomes once the file it points at is judged to be a
-- different file. An emptied file is not a different file, so it keeps its own.
local function replaced_status(status)
  return status == "orphaned" and status or "mismatch"
end

-- The extmark has collapsed onto nothing, because the noted text was deleted.
-- Recapturing here would store an empty excerpt and leave the note pointing at
-- a range that says nothing about what it was written for.
local function is_degenerate(lines, start_line, end_line, start_col, end_col)
  for _, line in ipairs(anchor.extract(lines, start_line, end_line, start_col, end_col)) do
    if line:match("%S") then
      return false
    end
  end
  return true
end

local sign_key = { ok = "sign", stale = "stale_sign", mismatch = "mismatch_sign" }
local sign_hl = {
  ok = "ContextMarkSign",
  stale = "ContextMarkStale",
  mismatch = "ContextMarkMismatch",
}
local text_hl = {
  ok = "ContextMarkVirtualText",
  stale = "ContextMarkStale",
  mismatch = "ContextMarkMismatch",
}
local range_hl = {
  ok = "ContextMarkRange",
  stale = "ContextMarkStaleRange",
  mismatch = "ContextMarkMismatchRange",
}

local function summary(body)
  local first = body:gsub("\n.*", ""):gsub("%s+", " ")
  local maximum = config.get().display.max_virtual_text
  if vim.fn.strchars(first) > maximum then
    return vim.fn.strcharpart(first, 0, maximum - 1) .. "…"
  end
  return first
end

local function marker(group)
  local text
  if #group.items == 1 then
    text = " 󰍩 " .. summary(group.items[1].comment.body)
  else
    text = (" 󰍩 %d notes"):format(#group.items)
  end
  if group.severity == "mismatch" then
    text = text .. " (different file?)"
  end
  return {
    { text, text_hl[group.severity] },
  }
end

local function extmark_range(bufnr, mark_id)
  local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, mark_id, { details = true })
  if not position or not position[1] then
    return nil
  end
  local details = position[3] or {}
  local start_line = position[1] + 1
  local end_line = (details.end_row or position[1]) + 1
  return start_line, math.max(start_line, end_line), position[2], details.end_col or position[2]
end

function M.render(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local _, root, relative = buffer_context(bufnr)
  if not root then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  marks[bufnr] = {}
  local dirty = false
  local resolved = {}
  local line_groups = {}

  local comments = store.list(root, relative)
  -- Decide once, for the file as a whole, whether this is still the file the
  -- notes were written against. Per-note context cannot answer that.
  local verdict, fingerprint = "unknown", nil
  if #comments > 0 then
    verdict, fingerprint = identity.compare(store.fingerprint(root, relative), lines)
  end
  local replaced = verdict == "replaced"

  for _, comment in ipairs(comments) do
    local start_line, end_line, status, start_col, end_col = anchor.resolve(lines, comment.anchor)
    if start_line then
      if replaced then
        -- The text may well resolve -- a replacement file can repeat a template
        -- line at the very same position -- but it is not this note's text.
        status = replaced_status(status)
      end
      if
        comment.anchor.start_line ~= start_line
        or comment.anchor.end_line ~= end_line
        or comment.anchor.start_col ~= start_col
        or comment.anchor.end_col ~= end_col
        or comment.anchor.status ~= status
      then
        comment.anchor.start_line = start_line
        comment.anchor.end_line = end_line
        comment.anchor.start_col = start_col
        comment.anchor.end_col = end_col
        comment.anchor.status = status
        dirty = true
      end

      local severity = severity_of(status)
      local item = {
        comment = comment,
        start_line = start_line,
        end_line = end_line,
        start_col = start_col,
        end_col = end_col,
        severity = severity,
      }
      resolved[#resolved + 1] = item
      line_groups[start_line] = line_groups[start_line] or { items = {}, severity = "ok" }
      local group = line_groups[start_line]
      group.items[#group.items + 1] = item
      if severity_rank[severity] > severity_rank[group.severity] then
        group.severity = severity
      end
    end
  end

  local display = config.get().display
  for _, item in ipairs(resolved) do
    local group = line_groups[item.start_line]
    local primary = group.items[1] == item
    local options = {
      end_row = item.end_line - 1,
      end_col = item.end_col,
      hl_group = range_hl[item.severity],
      right_gravity = false,
      end_right_gravity = true,
      priority = 90,
    }
    if primary then
      options.sign_text = display[sign_key[group.severity]] or display.sign
      options.sign_hl_group = sign_hl[group.severity]
      options.virt_text = marker(group)
      options.virt_text_pos = "eol"
    end
    local mark_id =
      vim.api.nvim_buf_set_extmark(bufnr, namespace, item.start_line - 1, item.start_col, options)
    marks[bufnr][item.comment.id] = mark_id
  end

  -- Refresh the identity baseline only while it still holds. Keeping the old
  -- fingerprint through a replacement is what lets the notes recover on their
  -- own once the real file comes back to this path.
  if fingerprint and not replaced then
    local stored = store.fingerprint(root, relative)
    if not stored or stored.digest ~= fingerprint.digest then
      store.set_fingerprint(root, relative, fingerprint)
      dirty = true
    end
  end

  if dirty then
    store.save(root)
  end
end

function M.sync(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local _, root, relative = buffer_context(bufnr)
  if not root or not marks[bufnr] then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local dirty = false
  local comments = store.list(root, relative)

  -- The freeze is decided by file identity, not by the per-note status, so a
  -- note that resolved as healthy in a replacement file is protected too.
  local frozen = false
  if #comments > 0 then
    frozen = identity.compare(store.fingerprint(root, relative), lines) == "replaced"
  end

  local line_count = math.max(#lines, 1)
  local function clamp_line(value)
    return math.max(1, math.min(value, line_count))
  end
  local function clamp_col(line, value)
    return math.max(0, math.min(value, #(lines[line] or "")))
  end

  for _, comment in ipairs(comments) do
    local mark_id = marks[bufnr][comment.id]
    if mark_id then
      local start_line, end_line, start_col, end_col = extmark_range(bufnr, mark_id)
      if start_line then
        local stored = comment.anchor
        -- extmark positions can sit one row past the last line, so clamp them
        -- the way anchor.capture() would before they reach the sidecar.
        local first = clamp_line(start_line)
        local last = clamp_line(math.max(end_line, first))
        local first_col = clamp_col(first, start_col)
        local last_col = clamp_col(last, end_col)
        local degenerate = is_degenerate(lines, first, last, first_col, last_col)

        if frozen or degenerate then
          -- The stored excerpt and context are the only evidence left for
          -- re-attaching this note. Recapturing would replace the whole anchor
          -- table, overwriting that evidence with text the note was never
          -- written against -- or with nothing at all -- and reset the status to
          -- "exact", which made a broken note look healthy and unrecoverable.
          -- Follow the extmark position only.
          --
          -- This is deliberately keyed on the file's identity and on the range
          -- collapsing, NOT on the note's status: a note that still resolves
          -- cleanly inside a replacement file needs the same protection, and a
          -- note whose text was merely edited must still follow that edit.
          stored.start_line = first
          stored.end_line = last
          stored.start_col = first_col
          stored.end_col = last_col
          if frozen then
            stored.status = replaced_status(stored.status)
          elseif not util.is_warning_status(stored.status) then
            stored.status = "stale"
          end
        else
          comment.anchor = anchor.capture(lines, first, last, config.get().storage.context_lines, {
            kind = stored.kind,
            start_col = first_col,
            end_col = last_col,
          })
        end
        comment.updated_at = util.now()
        dirty = true
      end
    end
  end

  if dirty then
    store.save(root)
  end
end

function M.sync_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and marks[bufnr] then
      M.sync(bufnr)
    end
  end
end

function M.at_cursor_all(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local _, root, relative = buffer_context(bufnr)
  if not root then
    return {}, root
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local result = {}
  for _, comment in ipairs(store.list(root, relative)) do
    local mark_id = marks[bufnr] and marks[bufnr][comment.id]
    local start_line, end_line
    if mark_id then
      start_line, end_line = extmark_range(bufnr, mark_id)
    else
      start_line, end_line = comment.anchor.start_line, comment.anchor.end_line
    end
    if start_line and cursor_line >= start_line and cursor_line <= end_line then
      result[#result + 1] = comment
    end
  end
  return result, root
end

function M.at_cursor(bufnr)
  local comments, root = M.at_cursor_all(bufnr)
  return comments[1], root
end

function M.namespace()
  return namespace
end

return M
