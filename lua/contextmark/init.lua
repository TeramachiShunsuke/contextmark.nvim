local anchor = require("contextmark.anchor")
local config = require("contextmark.config")
local delivery = require("contextmark.delivery")
local prompt = require("contextmark.prompt")
local render = require("contextmark.render")
local selection = require("contextmark.selection")
local store = require("contextmark.store")
local ui = require("contextmark.ui")
local util = require("contextmark.util")

local M = {}
local configured = false

local function current_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local root = util.project_root(path)
  return bufnr, path, root, util.relative_path(path, root)
end

local function notify_save(ok, error_message)
  if not ok then
    vim.notify(
      "contextmark: could not save sidecar: " .. tostring(error_message),
      vim.log.levels.ERROR
    )
  end
end

function M.add()
  local bufnr, _, root, relative = current_context()
  if not bufnr then
    vim.notify("contextmark: current buffer has no file", vim.log.levels.WARN)
    return
  end
  local selected = selection.current()
  local start_line, end_line = selected.start_line, selected.end_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local captured =
    anchor.capture(lines, start_line, end_line, config.get().storage.context_lines, selected)

  ui.edit("", ("Note for %s:%d-%d"):format(relative, start_line, end_line), function(body)
    local now = util.now()
    local comment = {
      id = util.id(root, relative, body),
      file = relative,
      filetype = vim.bo[bufnr].filetype,
      body = body,
      created_at = now,
      updated_at = now,
      anchor = captured,
    }
    local ok, error_message = store.add(root, comment)
    notify_save(ok, error_message)
    render.render(bufnr)
  end)
end

function M.edit()
  local comment, root = render.at_cursor()
  if not comment then
    vim.notify("contextmark: no comment at cursor", vim.log.levels.WARN)
    return
  end
  ui.edit(comment.body, "Edit note", function(body)
    comment.body = body
    comment.updated_at = util.now()
    local ok, error_message = store.update(root, comment)
    notify_save(ok, error_message)
    render.render()
  end)
end

function M.delete()
  local comment, root = render.at_cursor()
  if not comment then
    vim.notify("contextmark: no comment at cursor", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "Cancel", "Delete" }, {
    prompt = ("Delete note at %s:%d?"):format(comment.file, comment.anchor.start_line),
  }, function(choice)
    if choice ~= "Delete" then
      return
    end
    local ok, error_message = store.remove(root, comment.id)
    notify_save(ok, error_message)
    render.render()
  end)
end

local function comments_for(scope)
  render.sync_all()
  local _, _, root, relative = current_context()
  if not root then
    return nil, {}
  end
  if scope == "current" then
    local comment = render.at_cursor()
    return root, comment and { comment } or {}
  elseif scope == "buffer" then
    return root, store.list(root, relative)
  end
  return root, store.list(root)
end

local function deliver(root, comments, mode)
  if #comments == 0 then
    vim.notify("contextmark: no comments for this scope", vim.log.levels.WARN)
    return nil
  end
  local text = prompt.build(root, comments)
  local ok, result = delivery.send(text, comments, mode)
  if not ok then
    vim.notify(
      "contextmark: could not deliver prompt: " .. (result.error or "unknown error"),
      vim.log.levels.ERROR
    )
    return nil, result
  end

  local routes = {}
  if result.direct.ok then
    routes[#routes + 1] = "direct"
  end
  if result.clipboard.ok then
    local label = result.clipboard.register == '"' and "Neovim register" or "clipboard"
    routes[#routes + 1] = label
  end
  local fallback = result.fallback and " (direct unavailable; fallback used)" or ""
  vim.notify(
    ("contextmark: delivered %d note(s) via %s%s"):format(
      #comments,
      table.concat(routes, " + "),
      fallback
    ),
    vim.log.levels.INFO
  )
  return text, result
end

function M.build_prompt(scope)
  local root, comments = comments_for(scope or "all")
  if not root or #comments == 0 then
    return nil, comments
  end
  return prompt.build(root, comments), comments
end

function M.export(scope, mode)
  scope = scope or "all"
  if not vim.tbl_contains({ "current", "buffer", "all", "select" }, scope) then
    vim.notify("contextmark: unknown prompt scope: " .. tostring(scope), vim.log.levels.ERROR)
    return
  end
  local root, comments = comments_for(scope)
  if scope == "select" then
    ui.select(comments, function(selected)
      deliver(root, selected, mode)
    end)
    return
  end
  return deliver(root, comments, mode)
end

function M.list()
  render.sync_all()
  local _, _, root = current_context()
  if not root then
    return
  end
  local items = {}
  for _, comment in ipairs(store.list(root)) do
    items[#items + 1] = {
      filename = util.absolute_path(root, comment.file),
      lnum = comment.anchor.start_line,
      end_lnum = comment.anchor.end_line,
      text = comment.body:gsub("\n", " "),
    }
  end
  vim.fn.setqflist({}, " ", { title = "contextmark", items = items })
  vim.cmd.copen()
end

function M.show(silent)
  local comments = render.at_cursor_all()
  if #comments == 0 then
    ui.close_hover()
    if not silent then
      vim.notify("contextmark: no comments at cursor", vim.log.levels.INFO)
    end
    return nil
  end
  return ui.hover(comments)
end

function M.goto_comment(direction)
  local _, _, root, relative = current_context()
  if not root then
    return
  end
  local comments = store.list(root, relative)
  if #comments == 0 then
    vim.notify("contextmark: no comments in this buffer", vim.log.levels.INFO)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  if direction > 0 then
    for _, comment in ipairs(comments) do
      if comment.anchor.start_line > cursor then
        vim.api.nvim_win_set_cursor(0, { comment.anchor.start_line, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { comments[1].anchor.start_line, 0 })
  else
    for index = #comments, 1, -1 do
      if comments[index].anchor.start_line < cursor then
        vim.api.nvim_win_set_cursor(0, { comments[index].anchor.start_line, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { comments[#comments].anchor.start_line, 0 })
  end
end

local function map_buffer(bufnr)
  local keys = config.get().keymaps
  local function map(modes, lhs, callback, description)
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set(modes, lhs, callback, { buffer = bufnr, silent = true, desc = description })
    end
  end
  map({ "n", "v" }, keys.add, M.add, "Markdown note: add")
  map("n", keys.edit, M.edit, "Markdown note: edit")
  map("n", keys.delete, M.delete, "Markdown note: delete")
  map("n", keys.show, M.show, "Markdown note: show")
  map("n", keys.next, function()
    M.goto_comment(1)
  end, "Markdown note: next")
  map("n", keys.prev, function()
    M.goto_comment(-1)
  end, "Markdown note: previous")
  map("n", keys.list, M.list, "Markdown note: list")
  map("n", keys.prompt_current, function()
    M.export("current")
  end, "Markdown note: prompt current")
  map("n", keys.prompt_buffer, function()
    M.export("buffer")
  end, "Markdown note: prompt buffer")
  map("n", keys.prompt_all, function()
    M.export("all")
  end, "Markdown note: prompt all")
  map("n", keys.prompt_select, function()
    M.export("select")
  end, "Markdown note: prompt select")
end

function M.setup(opts)
  config.setup(opts)
  vim.api.nvim_set_hl(0, "ContextMarkSign", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(
    0,
    "ContextMarkVirtualText",
    { link = "DiagnosticVirtualTextInfo", default = true }
  )
  vim.api.nvim_set_hl(0, "ContextMarkRange", { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "ContextMarkStale", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "ContextMarkStaleRange", { link = "DiagnosticWarn", default = true })

  local group = vim.api.nvim_create_augroup("contextmark", { clear = true })
  -- Matched here rather than through the autocmd pattern so that globs and
  -- predicate functions in `filetypes` behave identically across every event.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "*",
    callback = function(event)
      if util.is_filetype_allowed(vim.bo[event.buf].filetype, config.get().filetypes) then
        map_buffer(event.buf)
        render.render(event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(event)
      if util.is_filetype_allowed(vim.bo[event.buf].filetype, config.get().filetypes) then
        render.render(event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      if util.is_filetype_allowed(vim.bo[event.buf].filetype, config.get().filetypes) then
        render.sync(event.buf)
        render.render(event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function(event)
      if
        config.get().display.hover
        and util.is_filetype_allowed(vim.bo[event.buf].filetype, config.get().filetypes)
      then
        M.show(true)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" }, {
    group = group,
    callback = ui.close_hover,
  })
  configured = true
end

function M.is_configured()
  return configured
end

return M
