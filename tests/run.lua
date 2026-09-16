local anchor = require("contextmark.anchor")
local config = require("contextmark.config")
local delivery = require("contextmark.delivery")
local prompt = require("contextmark.prompt")

local tests = {}

local function test(name, callback)
  tests[#tests + 1] = { name = name, callback = callback }
end

local function equal(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

test("captures a line range and context", function()
  local result = anchor.capture({ "a", "b", "c", "d", "e" }, 2, 3, 1)
  equal(result.excerpt, { "b", "c" })
  equal(result.before, { "a" })
  equal(result.after, { "d" })
end)

test("resolves an unchanged anchor", function()
  local captured = anchor.capture({ "a", "b", "c" }, 2, 2, 1)
  equal({ anchor.resolve({ "a", "b", "c" }, captured) }, { 2, 2, "exact", 0, 1 })
end)

test("follows selected text when lines are inserted", function()
  local captured = anchor.capture({ "a", "target", "z" }, 2, 2, 1)
  equal({ anchor.resolve({ "new", "a", "target", "z" }, captured) }, { 3, 3, "moved", 0, 6 })
end)

test("uses context to disambiguate duplicate text", function()
  local captured = anchor.capture({ "before", "same", "after" }, 2, 2, 1)
  local lines = { "same", "other", "before", "same", "after" }
  equal({ anchor.resolve(lines, captured) }, { 4, 4, "moved", 0, 4 })
end)

test("marks an unresolved changed excerpt as stale", function()
  local captured = anchor.capture({ "before", "target", "after" }, 2, 2, 0)
  equal({ anchor.resolve({ "before", "changed", "after" }, captured) }, { 2, 2, "stale", 0, 6 })
end)

test("captures and resolves an exact character selection", function()
  local text = "テストの文章です"
  local captured = anchor.capture({ text }, 1, 1, 0, {
    kind = "char",
    start_col = 0,
    end_col = #"テスト",
  })
  equal(captured.excerpt, { "テスト" })
  equal({ anchor.resolve({ text }, captured) }, { 1, 1, "exact", 0, #"テスト" })
end)

test("reads byte-accurate multibyte Visual selection", function()
  local selection = require("contextmark.selection")
  vim.cmd.enew({ bang = true })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "テストの文章です" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! v2l")
  local selected = selection.current()
  equal(selected.kind, "char")
  equal(selected.start_col, 0)
  equal(selected.end_col, #"テスト")
  equal(
    anchor.extract({ "テストの文章です" }, 1, 1, selected.start_col, selected.end_col),
    { "テスト" }
  )
end)

test("renders only the selected characters in the prompt excerpt", function()
  local util = require("contextmark.util")
  local original_reader = util.read_buffer_or_file
  util.read_buffer_or_file = function()
    return { "テストの文章です" }
  end
  local text = prompt.build("/project", {
    {
      file = "example.md",
      filetype = "markdown",
      body = "選択範囲へのNote",
      anchor = {
        start_line = 1,
        end_line = 1,
        start_col = 0,
        end_col = #"テスト",
        excerpt = { "テスト" },
      },
    },
  })
  util.read_buffer_or_file = original_reader
  assert(text:find("> テスト\n", 1, true))
  assert(not text:find("テストの文章です", 1, true))
end)

test("renders the Orca prompt contract", function()
  local original_reader = require("contextmark.util").read_buffer_or_file
  require("contextmark.util").read_buffer_or_file = function()
    return { "one", "two", "three", "four" }
  end

  local text = prompt.build("/project", {
    {
      file = "note.md",
      filetype = "markdown",
      body = "first\nsecond",
      anchor = { start_line = 2, end_line = 3, excerpt = { "two", "three" } },
    },
    {
      file = "note.md",
      filetype = "markdown",
      body = "single",
      anchor = { start_line = 4, end_line = 4, excerpt = { "four" } },
    },
  })

  require("contextmark.util").read_buffer_or_file = original_reader
  equal(
    text,
    table.concat({
      "File: note.md",
      "Source: markdown",
      "",
      "Lines 2-3",
      "Excerpt:",
      "> two",
      "> three",
      'User comment: "first\\nsecond"',
      "",
      "Line 4",
      "Excerpt:",
      "> four",
      'User comment: "single"',
    }, "\n")
  )
end)

test("auto delivery falls back to clipboard when direct is unavailable", function()
  config.setup({
    delivery = {
      mode = "auto",
      direct = {
        is_available = function()
          return false, "agent is not running"
        end,
        send = function()
          error("must not be called")
        end,
      },
      clipboard = { register = "z", fallback_register = '"' },
    },
  })
  local ok, result = delivery.send("fallback prompt", {})
  equal(ok, true)
  equal(result.direct.ok, false)
  equal(result.clipboard.ok, true)
  equal(result.fallback, true)
  equal(vim.fn.getreg("z"), "fallback prompt")
end)

test("both delivery uses direct and clipboard", function()
  local received
  config.setup({
    delivery = {
      mode = "both",
      direct = {
        send = function(text)
          received = text
          return { accepted = true }
        end,
      },
      clipboard = { register = "z", fallback_register = '"' },
    },
  })
  local ok, result = delivery.send("two routes", {})
  equal(ok, true)
  equal(result.direct.ok, true)
  equal(result.clipboard.ok, true)
  equal(received, "two routes")
  equal(vim.fn.getreg("z"), "two routes")
end)

test("clipboard delivery has an internal register fallback", function()
  config.setup({
    delivery = {
      mode = "clipboard",
      clipboard = { register = "", fallback_register = "y" },
    },
  })
  local ok, result = delivery.send("register fallback", {})
  equal(ok, true)
  equal(result.clipboard.register, "y")
  equal(vim.fn.getreg("y"), "register fallback")
end)

test("sidekick adapter preserves prompt text literally", function()
  local sidekick = require("contextmark.adapters.sidekick")
  equal(sidekick.to_text("{selection}\nline two"), {
    { { "{selection}" } },
    { { "line two" } },
  })
end)

test("saves a character-range note through the Ctrl-S editor callback", function()
  local state_dir = vim.fn.tempname()
  local plugin = require("contextmark")
  local store = require("contextmark.store")
  local util = require("contextmark.util")
  store.reset_cache()
  plugin.setup({ storage = { dir = state_dir, context_lines = 1 } })
  vim.cmd.edit("examples/feedback.md")
  local root = util.project_root(vim.api.nvim_buf_get_name(0))
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "テストの文章です" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! v2l")

  plugin.add()
  local editor = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "saved with Ctrl-S" })
  local submit
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(editor, "i")) do
    if mapping.lhs == "<C-S>" then
      submit = mapping.callback
      break
    end
  end
  assert(type(submit) == "function", "Ctrl-S callback was not registered")
  submit()

  local comments = store.list(root)
  equal(#comments, 1)
  equal(comments[1].body, "saved with Ctrl-S")
  equal(comments[1].anchor.excerpt, { "テスト" })
  assert(comments[1].id:match("^cm%-%x+$"), "comment id was not generated")
  local generated = prompt.build(root, comments)
  assert(generated:find("> テスト\n", 1, true))
  assert(not generated:find("テストの文章です", 1, true))
  vim.cmd.enew({ bang = true })
end)

test("direct delivery can disable clipboard fallback", function()
  config.setup({
    delivery = {
      mode = "direct",
      fallback_to_clipboard = false,
      direct = {
        send = function()
          return false, "agent rejected input"
        end,
      },
      clipboard = { register = "z", fallback_register = '"' },
    },
  })
  vim.fn.setreg("z", "unchanged")
  local ok, result = delivery.send("not delivered", {})
  equal(ok, false)
  equal(result.clipboard.attempted, false)
  equal(vim.fn.getreg("z"), "unchanged")
end)

test("collapses crowded line notes and shows every body in a hover", function()
  local state_dir = vim.fn.tempname()
  local plugin = require("contextmark")
  local store = require("contextmark.store")
  local util = require("contextmark.util")
  local render = require("contextmark.render")
  local ui = require("contextmark.ui")
  store.reset_cache()
  plugin.setup({ storage = { dir = state_dir, context_lines = 1 } })
  vim.cmd.edit("examples/feedback.md")

  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A crowded source line" })
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = util.project_root(path)
  local relative = util.relative_path(path, root)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local now = util.now()
  for index = 1, 6 do
    local ok = store.add(root, {
      id = "cm-crowded-" .. index,
      file = relative,
      filetype = "markdown",
      body = "hover body " .. index,
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(lines, 1, 1, 1),
    })
    equal(ok, true)
  end

  render.render(bufnr)
  local extmarks =
    vim.api.nvim_buf_get_extmarks(bufnr, render.namespace(), 0, -1, { details = true })
  equal(#extmarks, 6)
  local marker_count = 0
  local marker_text
  for _, extmark in ipairs(extmarks) do
    local virtual_text = extmark[4].virt_text
    if virtual_text and #virtual_text > 0 then
      marker_count = marker_count + 1
      marker_text = virtual_text[1][1]
    end
  end
  equal(marker_count, 1)
  assert(marker_text:find("6 notes", 1, true))

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local comments = render.at_cursor_all(bufnr)
  equal(#comments, 6)
  local window = plugin.show()
  assert(window and vim.api.nvim_win_is_valid(window))
  local hover_buffer = vim.api.nvim_win_get_buf(window)
  local hover_text = table.concat(vim.api.nvim_buf_get_lines(hover_buffer, 0, -1, false), "\n")
  assert(hover_text:find("hover body 1", 1, true))
  assert(hover_text:find("hover body 6", 1, true))
  ui.close_hover()

  local stale = vim.api.nvim_get_hl(0, { name = "ContextMarkStaleRange", link = true })
  equal(stale.link, "DiagnosticWarn")
  vim.cmd.enew({ bang = true })
end)

test("integrates storage, extmarks, commands, and prompt scope", function()
  local state_dir = vim.fn.tempname()
  local plugin = require("contextmark")
  plugin.setup({
    storage = { dir = state_dir, context_lines = 1 },
    delivery = { mode = "clipboard", clipboard = { register = "z", fallback_register = '"' } },
  })
  vim.cmd.edit("README.md")

  local store = require("contextmark.store")
  local util = require("contextmark.util")
  local render = require("contextmark.render")
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = util.project_root(path)
  local relative = util.relative_path(path, root)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local now = util.now()
  local comment = {
    id = "cm-integration",
    file = relative,
    filetype = "markdown",
    body = "integration note",
    created_at = now,
    updated_at = now,
    anchor = anchor.capture(lines, 1, 1, 1),
  }

  local ok, error_message = store.add(root, comment)
  equal(ok, true)
  equal(error_message, nil)
  equal(vim.fn.filereadable(store.path(root)), 1)

  render.render(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, render.namespace(), 0, -1, {})
  equal(#marks, 1)
  equal(vim.fn.exists(":ContextMarkSend"), 2)
  equal(vim.fn.exists(":ContextMarkSendDirect"), 2)
  equal(vim.fn.exists(":ContextMarkSendClipboard"), 2)
  equal(vim.fn.exists(":ContextMarkShow"), 2)

  local text, selected = plugin.build_prompt("buffer")
  equal(#selected, 1)
  assert(text:find("File: README.md", 1, true))
  assert(text:find('User comment: "integration note"', 1, true))
end)

test("setup initializes already-open allowed buffers", function()
  local config = require("contextmark.config")
  local plugin = require("contextmark")
  local render = require("contextmark.render")
  local store = require("contextmark.store")
  local util = require("contextmark.util")
  local state_dir = vim.fn.tempname()

  store.reset_cache()
  vim.cmd.edit("examples/feedback.md")
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = util.project_root(path)
  local relative = util.relative_path(path, root)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local now = util.now()

  config.setup({
    storage = { dir = state_dir },
    filetypes = { "*" },
    keymaps = { add = "gmc" },
  })
  local ok = store.add(root, {
    id = "cm-setup-existing-buffer",
    file = relative,
    filetype = vim.bo[bufnr].filetype,
    body = "existing buffer note",
    created_at = now,
    updated_at = now,
    anchor = anchor.capture(lines, 1, 1, 1),
  })
  equal(ok, true)

  vim.api.nvim_buf_clear_namespace(bufnr, render.namespace(), 0, -1)
  plugin.setup({
    storage = { dir = state_dir },
    filetypes = { "*" },
    keymaps = { add = "gmc" },
  })

  local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local found = false
  for _, mapping in ipairs(keymaps) do
    if mapping.lhs == "gmc" then
      found = true
      break
    end
  end
  equal(found, true)

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, render.namespace(), 0, -1, {})
  equal(#marks > 0, true)
  vim.cmd.enew({ bang = true })
end)

test("matches filetypes by name, glob, and predicate", function()
  local util = require("contextmark.util")
  local defaults = { "markdown", "markdown.mdx" }
  equal(util.is_filetype_allowed("markdown", defaults), true)
  equal(util.is_filetype_allowed("markdown.mdx", defaults), true)
  equal(util.is_filetype_allowed("lua", defaults), false)

  -- "*" spans any characters, but a literal "." in a glob must stay literal:
  -- "markdown.*" must not match "markdownfoo", which has no dot.
  equal(util.is_filetype_allowed("markdown.mdx", { "markdown*" }), true)
  equal(util.is_filetype_allowed("markdownfoo", { "markdown.*" }), false)
  equal(util.is_filetype_allowed("typescriptreact", { "*script*" }), true)

  equal(util.is_filetype_allowed("anything", { "*" }), true)
  equal(util.is_filetype_allowed("", { "*" }), true)
  equal(util.is_filetype_allowed("lua", "*"), true)

  equal(
    util.is_filetype_allowed("python", function(filetype)
      return filetype ~= "markdown"
    end),
    true
  )
  equal(
    util.is_filetype_allowed("markdown", function(filetype)
      return filetype ~= "markdown"
    end),
    false
  )
end)

test("resolves a symlinked project root to one location", function()
  local util = require("contextmark.util")
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/real/.git", "p")
  assert(vim.uv.fs_symlink(base .. "/real", base .. "/link", { dir = true }))

  local through_link = util.project_root(base .. "/link/note.md")
  local through_real = util.project_root(base .. "/real/note.md")
  equal(through_link, through_real)
  equal(util.relative_path(base .. "/link/note.md", through_link), "note.md")

  vim.fn.delete(base, "rf")
end)

test("preserves nested relative paths under symlinked roots for new files", function()
  local util = require("contextmark.util")
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/real/.git", "p")
  assert(vim.uv.fs_symlink(base .. "/real", base .. "/link", { dir = true }))

  local path_through_link = base .. "/link/sub/note.md"
  local path_through_real = base .. "/real/sub/note.md"
  local root = util.project_root(path_through_link)
  equal(root, util.project_root(path_through_real))
  equal(util.relative_path(path_through_link, root), "sub/note.md")

  vim.fn.delete(base, "rf")
end)

test("FileType autocmd applies glob and predicate filetypes", function()
  local plugin = require("contextmark")
  local storage = { dir = vim.fn.tempname() }

  local function has_add_keymap(filetype)
    vim.cmd.enew({ bang = true })
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = filetype
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if mapping.lhs == "gmc" then
        return true
      end
    end
    return false
  end

  plugin.setup({ storage = storage, filetypes = { "markdown*" }, keymaps = { add = "gmc" } })
  equal(has_add_keymap("markdown.mdx"), true)
  equal(has_add_keymap("lua"), false)

  plugin.setup({
    storage = storage,
    filetypes = function(filetype)
      return filetype == "python"
    end,
    keymaps = { add = "gmc" },
  })
  equal(has_add_keymap("python"), true)
  equal(has_add_keymap("markdown"), false)

  vim.cmd.enew({ bang = true })
end)

test("merges sidecars saved under a symlinked root into the canonical root", function()
  local config = require("contextmark.config")
  local store = require("contextmark.store")
  local util = require("contextmark.util")
  local base = vim.fn.tempname()
  local state_dir = base .. "/state"
  vim.fn.mkdir(base .. "/real/.git", "p")
  vim.fn.mkdir(state_dir, "p")
  assert(vim.uv.fs_symlink(base .. "/real", base .. "/link", { dir = true }))
  config.setup({ storage = { dir = state_dir } })
  store.reset_cache()

  local function note(id)
    return { id = id, file = "note.md", body = id, created_at = id, anchor = { start_line = 1 } }
  end
  local function write_state(root, comments)
    local encoded = vim.json.encode({ version = 1, root = root, comments = comments })
    vim.fn.writefile({ encoded }, store.path(root))
  end

  -- Before canonicalization the link path itself was the root.
  local legacy_root = vim.fs.normalize(base .. "/link")
  local root = util.project_root(base .. "/link/note.md")
  write_state(legacy_root, { note("cm-legacy"), note("cm-shared") })
  write_state(root, { note("cm-shared"), note("cm-current") })

  local ids = vim.tbl_map(function(comment)
    return comment.id
  end, store.list(root))
  table.sort(ids)
  equal(ids, { "cm-current", "cm-legacy", "cm-shared" })
  equal(vim.uv.fs_stat(store.path(legacy_root)), nil)
  assert(vim.uv.fs_stat(store.path(legacy_root) .. ".migrated"))

  -- The merge is persisted, so a fresh load sees the same notes.
  store.reset_cache()
  equal(#store.list(root), 3)

  store.reset_cache()
  vim.fn.delete(base, "rf")
end)

local failures = 0
for _, item in ipairs(tests) do
  local ok, error_message = pcall(item.callback)
  if ok then
    print("ok - " .. item.name)
  else
    failures = failures + 1
    print("not ok - " .. item.name .. ": " .. tostring(error_message))
  end
end

if failures > 0 then
  vim.cmd.cquit(failures)
end
print(("%d tests passed"):format(#tests))
