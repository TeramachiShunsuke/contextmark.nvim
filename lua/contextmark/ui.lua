local util = require("contextmark.util")
local config = require("contextmark.config")

local M = {}
local hover_window

local function dimensions(max_width, max_height)
  local width = math.max(40, math.min(max_width, vim.o.columns - 6))
  local height = math.max(4, math.min(max_height, vim.o.lines - 6))
  return width, height
end

local function hover_lines(comments)
  local lines = {}
  for index, comment in ipairs(comments) do
    local location = util.range_label(comment.anchor.start_line, comment.anchor.end_line)
    local warning = util.status_label(comment.anchor.status)
    lines[#lines + 1] = ("Note %d/%d · %s%s"):format(
      index,
      #comments,
      location,
      warning and (" · " .. warning) or ""
    )
    for _, line in ipairs(vim.split(comment.body, "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
    if index < #comments then
      lines[#lines + 1] = ""
    end
  end
  return lines
end

local function hover_dimensions(lines)
  local display = config.get().display
  local max_width = math.max(1, math.min(display.hover_max_width, vim.o.columns - 4))
  local max_height = math.max(1, math.min(display.hover_max_height, vim.o.lines - 4))
  local longest = 1
  for _, line in ipairs(lines) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line))
  end
  local minimum = math.min(32, max_width)
  local width = math.max(minimum, math.min(longest + 2, max_width))
  local wrapped_height = 0
  for _, line in ipairs(lines) do
    wrapped_height = wrapped_height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  return width, math.min(wrapped_height, max_height)
end

function M.close_hover()
  if hover_window and vim.api.nvim_win_is_valid(hover_window) then
    vim.api.nvim_win_close(hover_window, true)
  end
  hover_window = nil
end

function M.hover(comments)
  M.close_hover()
  if #comments == 0 then
    return nil
  end

  local lines = hover_lines(comments)
  local width, height = hover_dimensions(lines)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false

  hover_window = vim.api.nvim_open_win(buffer, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    border = "rounded",
    title = (" ContextMark · %d note%s "):format(#comments, #comments == 1 and "" or "s"),
    title_pos = "center",
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = 60,
  })
  vim.wo[hover_window].wrap = true
  vim.wo[hover_window].linebreak = true
  vim.wo[hover_window].conceallevel = 0
  return hover_window
end

function M.edit(initial, title, callback)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(initial or "", "\n", { plain = true }))

  local width, height = dimensions(88, 12)
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    title = " " .. title .. " — <C-s> save, q cancel ",
    title_pos = "center",
  })
  vim.wo[window].wrap = true
  vim.wo[window].linebreak = true

  local done = false
  local function close()
    if done then
      return
    end
    done = true
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end
  local function submit()
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"))
    close()
    if body ~= "" then
      callback(body)
    end
  end

  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "q", close, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buffer, nowait = true })
  vim.cmd.startinsert()
end

function M.select(comments, callback)
  if #comments == 0 then
    vim.notify("contextmark: no comments", vim.log.levels.INFO)
    return
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "contextmark-select"
  local selected = {}
  for index = 1, #comments do
    selected[index] = true
  end

  local function item_line(index)
    local comment = comments[index]
    local checked = selected[index] and "x" or " "
    local location = util.range_label(comment.anchor.start_line, comment.anchor.end_line)
    local body = comment.body:gsub("\n.*", ""):gsub("%s+", " ")
    return ("[%s] %s:%s  %s"):format(checked, comment.file, location:gsub("Lines? ", ""), body)
  end

  local function redraw(cursor)
    local lines = {
      "Space toggle · a all · n none · <CR> export · q cancel",
      "",
    }
    for index = 1, #comments do
      lines[#lines + 1] = item_line(index)
    end
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    if cursor then
      vim.api.nvim_win_set_cursor(0, { cursor, 0 })
    end
  end

  redraw()
  local width, height = dimensions(110, math.min(#comments + 2, 24))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    title = " Select notes for prompt ",
    title_pos = "center",
  })
  vim.wo[window].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end
  local function current_index()
    local row = vim.api.nvim_win_get_cursor(window)[1]
    return row >= 3 and row - 2 or nil, row
  end

  vim.keymap.set("n", "<Space>", function()
    local index, row = current_index()
    if index and comments[index] then
      selected[index] = not selected[index]
      redraw(row)
    end
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "a", function()
    for index = 1, #comments do
      selected[index] = true
    end
    redraw(vim.api.nvim_win_get_cursor(window)[1])
  end, { buffer = buffer })
  vim.keymap.set("n", "n", function()
    for index = 1, #comments do
      selected[index] = false
    end
    redraw(vim.api.nvim_win_get_cursor(window)[1])
  end, { buffer = buffer })
  vim.keymap.set("n", "<CR>", function()
    local result = {}
    for index, comment in ipairs(comments) do
      if selected[index] then
        result[#result + 1] = comment
      end
    end
    if #result == 0 then
      vim.notify("contextmark: select at least one comment", vim.log.levels.WARN)
      return
    end
    close()
    callback(result)
  end, { buffer = buffer })
  vim.keymap.set("n", "q", close, { buffer = buffer })
  vim.keymap.set("n", "<Esc>", close, { buffer = buffer })
  vim.api.nvim_win_set_cursor(window, { 3, 0 })
end

return M
