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

-- The identity verdict for a buffer, remembered per change. A single :w runs
-- both sync and render, and every BufEnter runs render again, so recomputing
-- hashed the whole document several times for one user action.
local verdicts = {}

local function file_verdict(bufnr, root, relative, lines)
  local stored = store.fingerprint(root, relative)
  local tick = vim.b[bufnr].changedtick
  local cached = verdicts[bufnr]
  if cached and cached.tick == tick and cached.relative == relative and cached.stored == stored then
    return cached.verdict, cached.fingerprint
  end
  local verdict, fingerprint = identity.compare(stored, lines)
  verdicts[bufnr] = {
    tick = tick,
    relative = relative,
    stored = stored,
    verdict = verdict,
    fingerprint = fingerprint,
  }
  return verdict, fingerprint
end

-- Reported once per root: a sidecar that cannot be written means the notes just
-- made are not on disk, and this used to be swallowed entirely.
local reported = {}

local function persist(root)
  local ok, error_message = store.save(root)
  if ok then
    reported[root] = nil
    return
  end
  if not reported[root] then
    reported[root] = true
    vim.notify(
      "contextmark: could not save sidecar: " .. tostring(error_message),
      vim.log.levels.ERROR
    )
  end
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

-- `stored` is the note's anchor, used to tell a pushed end from a note that
-- genuinely ends on an empty line.
local function extmark_range(bufnr, mark_id, stored)
  local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, mark_id, { details = true })
  if not position or not position[1] then
    return nil
  end
  local details = position[3] or {}
  local start_line = position[1] + 1
  local end_line = math.max(start_line, (details.end_row or position[1]) + 1)
  local end_col = details.end_col or position[2]
  -- Replacing the noted line pushes the end (right gravity) to column 0 of the
  -- next row. That is the same range as the end of the previous line; reading
  -- it literally adds an empty line to the excerpt. A note that really ends on
  -- an empty line has the same shape, so only trim a row the note never had.
  local span = stored
    and stored.start_line
    and stored.end_line
    and (stored.end_line - stored.start_line)
  if end_line > start_line and end_col == 0 and span and end_line - start_line > span then
    end_line = end_line - 1
    end_col = #(vim.api.nvim_buf_get_lines(bufnr, end_line - 1, end_line, false)[1] or "")
  end
  return start_line, end_line, position[2], end_col
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
  -- With unsaved edits the extmarks are ahead of the sidecar: they have followed
  -- the edits, the stored anchors have not. Re-resolving from the sidecar here
  -- (every BufEnter does) threw that tracking away and put notes on whatever
  -- text now sits at their old lines, which the next :w then recaptured. Keep
  -- the live positions instead, without writing them: the draft may yet be
  -- discarded, and the sidecar must keep describing the file on disk.
  local live = {}
  if marks[bufnr] and vim.bo[bufnr].modified then
    local anchors = {}
    for _, comment in ipairs(store.list(root, relative)) do
      anchors[comment.id] = comment.anchor
    end
    for id, mark_id in pairs(marks[bufnr]) do
      local start_line, end_line, start_col, end_col = extmark_range(bufnr, mark_id, anchors[id])
      if start_line then
        live[id] = { start_line, end_line, start_col, end_col }
      end
    end
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
  local suspected = false
  for _, comment in ipairs(comments) do
    if util.is_warning_status(comment.anchor.status) then
      suspected = true
      break
    end
  end
  if #comments > 0 then
    verdict, fingerprint = file_verdict(bufnr, root, relative, lines)
  end
  local replaced = verdict == "replaced"

  for _, comment in ipairs(comments) do
    local start_line, end_line, status, start_col, end_col
    local tracked = not replaced and live[comment.id]
    if tracked then
      start_line, end_line, start_col, end_col = unpack(tracked)
      status = comment.anchor.status
    else
      start_line, end_line, status, start_col, end_col = anchor.resolve(lines, comment.anchor)
    end
    -- A note recorded as healthy that fails to resolve in this render is as much
    -- a reason to withhold the baseline as one already stored as unresolved.
    if util.is_warning_status(status) then
      suspected = true
    end
    if start_line then
      if replaced then
        -- The text may well resolve -- a replacement file can repeat a template
        -- line at the very same position -- but it is not this note's text.
        -- Place it where it was recorded, not on the replacement's match: sync
        -- and the hover both read the extmark.
        status = replaced_status(status)
        local count = math.max(#lines, 1)
        start_line = math.max(1, math.min(comment.anchor.start_line, count))
        end_line = math.max(start_line, math.min(comment.anchor.end_line or start_line, count))
        start_col = math.max(0, math.min(comment.anchor.start_col or 0, #(lines[start_line] or "")))
        end_col = math.max(0, math.min(comment.anchor.end_col or 0, #(lines[end_line] or "")))
        if end_line == start_line and end_col < start_col then
          end_col = start_col
        end
      end
      if comment.anchor.status ~= status then
        comment.anchor.status = status
        dirty = true
      end
      -- Store the resolved position only while this is still the note's own
      -- file. Writing a replacement's coordinates back would make the prompt
      -- name this file's line numbers while quoting the original text, and
      -- would discard the last record of where the note actually was.
      if
        not replaced
        and not tracked
        and (
          comment.anchor.start_line ~= start_line
          or comment.anchor.end_line ~= end_line
          or comment.anchor.start_col ~= start_col
          or comment.anchor.end_col ~= end_col
        )
      then
        comment.anchor.start_line = start_line
        comment.anchor.end_line = end_line
        comment.anchor.start_col = start_col
        comment.anchor.end_col = end_col
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
  -- Only from text that is on disk: adopting an unsaved draft as the baseline
  -- leaves the note flagged against its own file once the draft is discarded.
  -- With no baseline yet and a note that already failed to resolve, there is
  -- nothing to say which file is the right one, and recording this one would
  -- make whichever was opened first the answer forever.
  local undecided = verdict == "unknown" and suspected
  if fingerprint and not replaced and not undecided and not vim.bo[bufnr].modified then
    local stored = store.fingerprint(root, relative)
    if not stored or stored.digest ~= fingerprint.digest then
      store.set_fingerprint(root, relative, fingerprint)
      dirty = true
    end
  end

  if dirty then
    persist(root)
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
    frozen = file_verdict(bufnr, root, relative, lines) == "replaced"
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
      local start_line, end_line, start_col, end_col = extmark_range(bufnr, mark_id, comment.anchor)
      if start_line then
        local stored = comment.anchor
        -- extmark positions can sit one row past the last line, so clamp them
        -- the way anchor.capture() would before they reach the sidecar.
        local first = clamp_line(start_line)
        local last = clamp_line(math.max(end_line, first))
        local first_col = clamp_col(first, start_col)
        local last_col = clamp_col(last, end_col)
        local degenerate = is_degenerate(lines, first, last, first_col, last_col)

        local before = vim.deepcopy(stored)
        if frozen then
          -- The file at this path is judged to be a different file. Its
          -- coordinates say nothing about where this note belongs, so neither the
          -- excerpt nor the position may be overwritten: the stored anchor is the
          -- only record left of where the note actually was, and the prompt
          -- would otherwise name this file's line numbers next to the original
          -- excerpt. Only the status is kept current.
          --
          -- This is keyed on the file's identity, NOT on the note's status: a
          -- note that still resolves cleanly inside a replacement file needs the
          -- same protection.
          stored.status = replaced_status(stored.status)
        elseif degenerate or util.is_warning_status(stored.status) then
          -- Either the extmark collapsed onto nothing (the noted text was
          -- deleted), or the note was already unresolved when it was placed, so
          -- its extmark sits on a fallback line rather than on its own text.
          -- Recapturing would replace the stored excerpt and context -- the only
          -- evidence for re-attaching it -- with unrelated text and reset the
          -- status to "exact", sending a broken note to the agent as a healthy
          -- one. Follow the extmark position only.
          stored.start_line = first
          stored.end_line = last
          stored.start_col = first_col
          stored.end_col = last_col
          if not util.is_warning_status(stored.status) then
            stored.status = "stale"
          end
        else
          -- A note that was placed on its own text follows edits to that text.
          comment.anchor = anchor.capture(lines, first, last, config.get().storage.context_lines, {
            kind = stored.kind,
            start_col = first_col,
            end_col = last_col,
          })
        end
        if not vim.deep_equal(before, comment.anchor) then
          comment.updated_at = util.now()
          dirty = true
        end
      end
    end
  end

  if dirty then
    persist(root)
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
      start_line, end_line = extmark_range(bufnr, mark_id, comment.anchor)
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
