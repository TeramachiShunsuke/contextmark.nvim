local anchor = require("contextmark.anchor")
local config = require("contextmark.config")
local store = require("contextmark.store")
local util = require("contextmark.util")

local M = {}
local namespace = vim.api.nvim_create_namespace("contextmark")
local marks = {}

local function buffer_context(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local root = util.project_root(path)
  return path, root, util.relative_path(path, root)
end

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
  return {
    { text, group.stale and "ContextMarkStale" or "ContextMarkVirtualText" },
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

  for _, comment in ipairs(store.list(root, relative)) do
    local start_line, end_line, status, start_col, end_col = anchor.resolve(lines, comment.anchor)
    if start_line then
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

      local stale = status == "stale" or status == "orphaned"
      local item = {
        comment = comment,
        start_line = start_line,
        end_line = end_line,
        start_col = start_col,
        end_col = end_col,
        stale = stale,
      }
      resolved[#resolved + 1] = item
      line_groups[start_line] = line_groups[start_line] or { items = {}, stale = false }
      local group = line_groups[start_line]
      group.items[#group.items + 1] = item
      group.stale = group.stale or stale
    end
  end

  local display = config.get().display
  for _, item in ipairs(resolved) do
    local group = line_groups[item.start_line]
    local primary = group.items[1] == item
    local options = {
      end_row = item.end_line - 1,
      end_col = item.end_col,
      hl_group = item.stale and "ContextMarkStaleRange" or "ContextMarkRange",
      right_gravity = false,
      end_right_gravity = true,
      priority = 90,
    }
    if primary then
      options.sign_text = group.stale and display.stale_sign or display.sign
      options.sign_hl_group = group.stale and "ContextMarkStale" or "ContextMarkSign"
      options.virt_text = marker(group)
      options.virt_text_pos = "eol"
    end
    local mark_id =
      vim.api.nvim_buf_set_extmark(bufnr, namespace, item.start_line - 1, item.start_col, options)
    marks[bufnr][item.comment.id] = mark_id
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

  for _, comment in ipairs(store.list(root, relative)) do
    local mark_id = marks[bufnr][comment.id]
    if mark_id then
      local start_line, end_line, start_col, end_col = extmark_range(bufnr, mark_id)
      if start_line then
        comment.anchor =
          anchor.capture(lines, start_line, end_line, config.get().storage.context_lines, {
            kind = comment.anchor.kind,
            start_col = start_col,
            end_col = end_col,
          })
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
