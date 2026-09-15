-- Visual and line selections for contextmark.nvim.
local M = {}

local function end_of_character(line, byte_col)
  local character = vim.fn.strcharpart(line:sub(byte_col + 1), 0, 1)
  return byte_col + #character
end

local function leave_visual_mode()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
end

function M.current()
  local mode = vim.fn.mode()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)

  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    local line = cursor[1]
    return {
      kind = "line",
      start_line = line,
      end_line = line,
      start_col = 0,
      end_col = #(lines[line] or ""),
    }
  end

  local first = { line = vim.fn.line("v"), col = vim.fn.col("v") - 1 }
  local last = { line = cursor[1], col = cursor[2] }
  if first.line > last.line or (first.line == last.line and first.col > last.col) then
    first, last = last, first
  end

  if mode == "V" or mode == "\22" then
    first.col = 0
    last.col = #(lines[last.line] or "")
    leave_visual_mode()
    return {
      kind = "line",
      start_line = first.line,
      end_line = last.line,
      start_col = first.col,
      end_col = last.col,
    }
  end

  if vim.o.selection ~= "exclusive" then
    last.col = end_of_character(lines[last.line] or "", last.col)
  end
  leave_visual_mode()
  return {
    kind = "char",
    start_line = first.line,
    end_line = last.line,
    start_col = first.col,
    end_col = last.col,
  }
end

return M
