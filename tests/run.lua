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

-- Builds a throwaway repository on disk with an isolated sidecar directory.
-- A real .git directory is required because util.project_root() keys on that
-- marker, and the files must exist because the identity checks resolve symlinks
-- and read the current text.
local function fixture(files)
  local store = require("contextmark.store")
  local util = require("contextmark.util")
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.git", "p")
  for name, lines in pairs(files or {}) do
    local path = root .. "/" .. name
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end
  store.reset_cache()
  require("contextmark").setup({ storage = { dir = vim.fn.tempname(), context_lines = 2 } })
  return util.normalize(root), store, util
end

-- The line a note is put on in the identity fixtures. Both the original and the
-- impostor carry it, so the excerpt still resolves and only the file's identity
-- can tell them apart.
local marked_line = "- [ ] ship the thing"
local marked_at = 3

-- A document long enough for the identity sample to mean something. Four-line
-- fixtures can only pin an over-aggressive threshold, which would then flag
-- everyday editing as a replaced file.
local function document(title)
  local lines = { "# " .. title, "" }
  for index = 1, 15 do
    lines[#lines + 1] = ("%s heading %d"):format(title, index)
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Prose from %s about point %d, written out at some length."):format(
      title,
      index
    )
    lines[#lines + 1] = ""
  end
  lines[marked_at] = marked_line
  return lines
end

-- Restores vim.ui.select even when an assertion inside fails. The runner wraps
-- each test in pcall, so a leaked stub would silently answer every later prompt.
local function with_select(choose, body)
  local original = vim.ui.select
  vim.ui.select = choose
  local ok, failure = pcall(body)
  vim.ui.select = original
  if not ok then
    error(failure, 0)
  end
end

local function add_note(root, relative, start_line, end_line, body)
  local store = require("contextmark.store")
  local identity = require("contextmark.identity")
  local util = require("contextmark.util")
  local lines = vim.fn.readfile(util.absolute_path(root, relative))
  local now = util.now()
  -- util.id() seeds on vim.uv.hrtime(), so repeated calls for the same file and
  -- line cannot collide. A derived id could, and render.sync() keys its extmark
  -- table on the id: a duplicate makes one note overwrite another's anchor.
  local ok, error_message = store.add(root, {
    id = util.id(root, relative, body or ("note " .. start_line)),
    file = relative,
    filetype = "markdown",
    body = body or "note body",
    created_at = now,
    updated_at = now,
    anchor = anchor.capture(lines, start_line, end_line, 2),
  })
  equal(ok, true)
  equal(error_message, nil)
  -- Mirror what render.render() does immediately after a note is created: the
  -- file as it stands at that moment becomes the identity baseline.
  store.set_fingerprint(root, relative, identity.fingerprint(lines))
  equal(store.save(root), true)
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

test("refuses a storage key for a file outside its root", function()
  local root, _, util = fixture()
  equal(util.relative_path("/definitely/not/here/notes.md", root), nil)
  equal(util.relative_path(root, root), nil)
  equal(util.relative_path(root .. "/docs/a.md", root), "docs/a.md")
end)

test("keys a file without a repository marker on its own directory", function()
  local util = require("contextmark.util")
  local directory = vim.fn.tempname()
  local elsewhere = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  vim.fn.mkdir(elsewhere, "p")
  local file = directory .. "/plain.md"
  vim.fn.writefile({ "text" }, file)

  local original_cwd = vim.fn.getcwd()
  local before = util.project_root(file)
  vim.cmd.cd(elsewhere)
  local after = util.project_root(file)
  vim.cmd.cd(original_cwd)

  equal(before, util.normalize(directory))
  equal(after, before)
end)

test("refuses notes from scheme-prefixed and special buffers", function()
  local util = require("contextmark.util")
  equal(util.is_notable_path("fugitive:///private/tmp/r/.git//0/docs/a.md"), false)
  equal(util.is_notable_path("oil:///private/tmp/proj/docs"), false)
  equal(util.is_notable_path("term:///private/tmp//4242:zsh"), false)
  equal(util.is_notable_path(""), false)
  equal(util.is_notable_path("/private/tmp/real.md"), true)

  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = "nofile"
  local context = util.buffer_context(bufnr)
  vim.cmd.enew({ bang = true })
  equal(context, nil)
end)

test("absolute_path returns exactly one value", function()
  local util = require("contextmark.util")
  equal(select("#", util.absolute_path("/private/tmp", "missing.md")), 1)
  -- vim.fn.filereadable() raises E118 when handed a multi-value expression.
  equal(vim.fn.filereadable(util.absolute_path("/private/tmp", "missing.md")), 0)
end)

test("reads the exact file instead of a pattern-matched buffer", function()
  local root, _, util = fixture({
    ["docs/a.md"] = { "real content" },
    ["docs/a.md.bak"] = { "BACKUP content" },
  })
  vim.cmd.edit(root .. "/docs/a.md.bak")
  local lines = util.read_buffer_or_file(root .. "/docs/a.md")
  vim.cmd.enew({ bang = true })
  equal(lines, { "real content" })
end)

test("does not attach notes to a renamed file's new path", function()
  local root, store = fixture({ ["docs/a.md"] = { "# Doc", "intro", "- [ ] item", "tail" } })
  add_note(root, "docs/a.md", 3, 3)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/b.md"), 0)

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/b.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, render.namespace(), 0, -1, {})
  vim.cmd.enew({ bang = true })

  equal(#marks, 0)
  equal(#store.list(root, "docs/b.md"), 0)
  equal(#store.list(root, "docs/a.md"), 1)
end)

test("flags a different file at the same path as a mismatch", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/b.md"), 0)
  -- The replacement is a different document that happens to carry the same
  -- checklist line, which used to resolve as "exact" and render in the healthy
  -- colour with no warning anywhere.
  vim.fn.writefile(document("Beta"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local extmarks =
    vim.api.nvim_buf_get_extmarks(bufnr, render.namespace(), 0, -1, { details = true })
  vim.cmd.enew({ bang = true })

  equal(#extmarks, 1)
  equal(store.list(root, "docs/a.md")[1].anchor.status, "mismatch")
  equal(extmarks[1][4].hl_group, "ContextMarkMismatchRange")
  equal(extmarks[1][4].virt_text[1][2], "ContextMarkMismatch")
  assert(
    extmarks[1][4].virt_text[1][1]:find("different file?", 1, true),
    "the mismatch marker was not labelled"
  )
end)

test("keeps an edited file's unresolved note as stale", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  -- Same document, the noted line rewritten: everything around it still
  -- matches, so this stays a plain stale note rather than escalating.
  local edited = document("Alpha")
  edited[marked_at] = "- [x] shipped it"
  vim.fn.writefile(edited, root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  vim.cmd.enew({ bang = true })

  equal(store.list(root, "docs/a.md")[1].anchor.status, "stale")
end)

test("flags a note whose file became empty as orphaned", function()
  local captured = anchor.capture({ "# Doc", "intro", "target", "tail" }, 3, 3, 2)
  equal({ anchor.resolve({ "" }, captured) }, { 1, 1, "orphaned", 0, 0 })
  equal({ anchor.resolve({}, captured) }, { 1, 1, "orphaned", 0, 0 })
end)

test("sync keeps the stored evidence of an unresolved note", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/b.md"), 0)
  vim.fn.writefile(document("Beta"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  render.sync(bufnr)
  vim.cmd.enew({ bang = true })

  -- Recapturing here would replace the excerpt with the wrong file's text and
  -- reset the status to "exact", losing the only evidence for re-attaching.
  local original = document("Alpha")
  local comment = store.list(root, "docs/a.md")[1]
  equal(comment.anchor.excerpt, { marked_line })
  equal(comment.anchor.before, { original[1], original[2] })
  equal(comment.anchor.after, { original[4], original[5] })
  equal(comment.anchor.status, "mismatch")
end)

test("freezes sync on a replaced file even while the note looks healthy", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local healthy = store.list(root, "docs/a.md")[1].anchor.status

  -- Swap the whole content without rendering again: a checkout or an external
  -- rewrite followed by :w reaches sync with the note still marked healthy, so
  -- a guard that only looked at the note's status would recapture here.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, document("Beta"))
  render.sync(bufnr)
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  local original = document("Alpha")
  equal(healthy, "exact")
  equal(comment.anchor.excerpt, { marked_line })
  equal(comment.anchor.before, { original[1], original[2] })
  equal(comment.anchor.status, "mismatch")
end)

test("never writes a position past the end of the buffer", function()
  local root, store =
    fixture({ ["docs/a.md"] = { "# Doc", "intro", "target one", "target two", "tail" } })
  add_note(root, "docs/a.md", 3, 4)

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  -- Cut the buffer down below the note. Neovim reports the surviving extmark at
  -- the end-of-buffer row, which is one past the last line, so the guarded
  -- branch has to clamp it the way anchor.capture() would.
  vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, {})
  render.sync(bufnr)
  local comment = store.list(root, "docs/a.md")[1]
  local line_count = #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.cmd.enew({ bang = true })

  equal(line_count, 1)
  equal(comment.anchor.start_line, 1)
  equal(comment.anchor.end_line, 1)
  equal(comment.anchor.start_col, 0)
  equal(comment.anchor.end_col, 0)
  -- The evidence still has to be there: this note is recoverable by undo.
  equal(comment.anchor.excerpt, { "target one", "target two" })
end)

test("sync still recaptures context for a healthy note", function()
  local root, store = fixture({ ["docs/a.md"] = { "# Doc", "intro", "- [ ] item", "tail" } })
  add_note(root, "docs/a.md", 3, 3)

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  -- Rewrite the first line. Editing the line directly above the note would drag
  -- the left-gravity extmark start onto it and widen the captured range, which
  -- is a separate pre-existing behaviour and not what this test is about.
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "# Rewritten doc" })
  render.sync(bufnr)
  vim.cmd.enew({ bang = true })

  local comment = store.list(root, "docs/a.md")[1]
  equal(comment.anchor.excerpt, { "- [ ] item" })
  equal(comment.anchor.before, { "# Rewritten doc", "intro" })
  equal(comment.anchor.status, "exact")
end)

test("flags a mismatch even when the excerpt moved to another line", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/b.md"), 0)
  -- Same checklist line, different position. Nothing in the anchor's own
  -- context can tell this from a real move, which is why the verdict comes
  -- from the file-level fingerprint instead.
  local impostor = document("Beta")
  impostor[marked_at] = "Beta heading 1"
  impostor[9] = marked_line
  vim.fn.writefile(impostor, root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  vim.cmd.enew({ bang = true })

  local comment = store.list(root, "docs/a.md")[1]
  equal(comment.anchor.status, "mismatch")
  equal(comment.anchor.start_line, 9)
end)

test("keeps the mismatch verdict through blank-padded Markdown", function()
  -- The note's neighbours are blank lines, which match in any document. A
  -- context-only check reports this file as healthy; the fingerprint does not.
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/b.md"), 0)
  vim.fn.writefile(document("Beta"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  vim.cmd.enew({ bang = true })

  equal(store.list(root, "docs/a.md")[1].anchor.status, "mismatch")
end)

test("does not accuse a file that only shares one template line", function()
  -- The inverse failure: an edited file that still holds most of its lines must
  -- stay healthy even though the noted line and its neighbours all changed.
  local root, store = fixture({
    ["docs/a.md"] = {
      "# Design doc",
      "paragraph one",
      "paragraph two",
      "- [ ] item",
      "paragraph three",
      "paragraph four",
      "## Details",
      "paragraph five",
    },
  })
  add_note(root, "docs/a.md", 4, 4)
  -- Same document, headings renamed and the noted line rewritten.
  vim.fn.writefile({
    "# Design notes",
    "paragraph one",
    "paragraph two",
    "- [x] item done",
    "paragraph three",
    "paragraph four",
    "## Detail",
    "paragraph five",
  }, root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  vim.cmd.enew({ bang = true })

  equal(store.list(root, "docs/a.md")[1].anchor.status, "stale")
end)

test("recovers on its own when the original file returns to the path", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local original = vim.fn.readfile(root .. "/docs/a.md")
  add_note(root, "docs/a.md", marked_at, marked_at)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/b.md"), 0)
  vim.fn.writefile(document("Beta"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  -- A save while the impostor is in place must not refresh the baseline, or the
  -- note could never find its way back.
  render.sync(bufnr)
  local flagged = store.list(root, "docs/a.md")[1].anchor.status
  vim.cmd.enew({ bang = true })

  vim.fn.writefile(original, root .. "/docs/a.md")
  vim.cmd.edit(root .. "/docs/a.md")
  local restored_buffer = vim.api.nvim_get_current_buf()
  render.render(restored_buffer)
  vim.cmd.enew({ bang = true })

  local comment = store.list(root, "docs/a.md")[1]
  equal(flagged, "mismatch")
  equal(comment.anchor.status, "exact")
  equal(comment.anchor.excerpt, { marked_line })
end)

test("compares file identity by surviving content", function()
  local identity = require("contextmark.identity")
  local body = {}
  for index = 1, 12 do
    body[index] = "line " .. index
  end
  local baseline = identity.fingerprint(body)

  equal(select(1, identity.compare(baseline, body)), "same")
  equal(select(1, identity.compare(nil, body)), "unknown")

  local edited = vim.deepcopy(body)
  edited[3] = "line three rewritten"
  edited[7] = "line seven rewritten"
  table.insert(edited, "line 13")
  equal(select(1, identity.compare(baseline, edited)), "same")

  local replaced = {}
  for index = 1, 12 do
    replaced[index] = "completely different " .. index
  end
  equal(select(1, identity.compare(baseline, replaced)), "replaced")

  -- Blank lines carry no signal, so a document made only of them is undecidable
  -- rather than a replacement.
  equal(select(1, identity.compare(identity.fingerprint({ "", "", "" }), { "x" })), "unknown")

  -- A sample too small for a ratio only decides when nothing at all survived.
  local tiny = identity.fingerprint({ "only line" })
  equal(select(1, identity.compare(tiny, { "only line", "added" })), "same")
  equal(select(1, identity.compare(tiny, { "something else" })), "replaced")
end)

test("marks an unresolved note in the prompt it sends", function()
  local util = require("contextmark.util")
  local original_reader = util.read_buffer_or_file
  util.read_buffer_or_file = function()
    return { "an impostor line", "another impostor line" }
  end
  local text = prompt.build("/project", {
    {
      file = "note.md",
      filetype = "markdown",
      body = "keep this",
      anchor = {
        start_line = 1,
        end_line = 1,
        start_col = 0,
        end_col = 6,
        excerpt = { "target" },
        status = "mismatch",
      },
    },
  })
  util.read_buffer_or_file = original_reader

  -- The excerpt must be the stored text, not the impostor's, and the agent must
  -- be told the note could not be placed.
  assert(text:find("Status: different file?", 1, true), "the prompt carried no status")
  assert(text:find("> target", 1, true), "the stored excerpt was not used")
  assert(not text:find("impostor", 1, true), "the prompt quoted the wrong file")
end)

test("gives a symlinked file and its target the same key", function()
  local root, _, util = fixture({ ["docs/real.md"] = { "content" } })
  local link = root .. "/docs/alias.md"
  assert(vim.uv.fs_symlink(root .. "/docs/real.md", link), "could not create the symlink")
  -- Neovim resolves the directory part of a buffer name but not the file
  -- itself, so without this both spellings would own separate notes.
  equal(util.relative_path(link, root), "docs/real.md")
  equal(util.relative_path(root .. "/docs/real.md", root), "docs/real.md")
end)

test("keeps a link that escapes the repository keyed inside it", function()
  local root, _, util = fixture({ ["docs/keep.md"] = { "content" } })
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "outside content" }, outside .. "/ext.md")
  local link = root .. "/docs/ext.md"
  assert(vim.uv.fs_symlink(outside .. "/ext.md", link), "could not create the symlink")

  -- Resolving before looking for the marker would hand this note to the link
  -- target's own root and drop it out of this project's sidecar entirely.
  equal(util.project_root(link), root)
  equal(util.relative_path(link, root), "docs/ext.md")
end)

test("never produces a doubled leading slash", function()
  local util = require("contextmark.util")
  local missing = "/contextmark-no-such-file.md"
  equal(util.normalize(missing), missing)
  equal(util.absolute_path("/", "contextmark-no-such-file.md"), missing)
end)

test("refuses notes from a special buftype even with a real file name", function()
  local root, _, util = fixture({ ["docs/a.md"] = { "content" } })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, root .. "/docs/a.md")
  vim.bo[bufnr].buftype = ""
  local allowed = util.buffer_context(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  local refused = util.buffer_context(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  equal(allowed, root .. "/docs/a.md")
  equal(refused, nil)
end)

test("labels every unresolved status", function()
  local util = require("contextmark.util")
  equal(util.status_label("mismatch"), "different file?")
  equal(util.status_label("stale"), "unresolved")
  equal(util.status_label("orphaned"), "file is empty")
  equal(util.status_label("exact"), nil)
  equal(util.status_label("moved"), nil)
  equal(util.is_warning_status("moved"), false)
  equal(util.is_warning_status("mismatch"), true)
  equal(util.status_note("exact"), nil)
  assert(util.status_note("stale"):find("^Status: unresolved"), "the stale prompt note changed")
end)

test("renders and preserves a note whose file became empty", function()
  local root, store = fixture({ ["docs/a.md"] = { "# Doc", "intro", "- [ ] item", "tail" } })
  add_note(root, "docs/a.md", 3, 3)
  vim.fn.writefile({}, root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local extmarks =
    vim.api.nvim_buf_get_extmarks(bufnr, render.namespace(), 0, -1, { details = true })
  render.sync(bufnr)
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  -- An empty file used to make resolve() return nil, which dropped the note
  -- from the render loop: the note vanished instead of being flagged.
  equal(#extmarks, 1)
  equal(extmarks[1][4].sign_text, "? ")
  equal(comment.anchor.status, "orphaned")
  equal(comment.anchor.excerpt, { "- [ ] item" })
end)

-- Writes the sidecar behind the cache's back, the way a second Neovim instance
-- editing the same project would leave it.
local function other_instance_adds(root, body)
  local store = require("contextmark.store")
  local util = require("contextmark.util")
  local path = store.path(root)
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  local now = util.now()
  decoded.comments[#decoded.comments + 1] = {
    id = "cm-other-" .. body:gsub("%W", ""),
    file = "docs/a.md",
    filetype = "markdown",
    body = body,
    created_at = now,
    updated_at = now,
    anchor = {
      kind = "line",
      start_line = 2,
      end_line = 2,
      start_col = 0,
      end_col = 5,
      excerpt = { "world" },
      status = "exact",
    },
  }
  vim.fn.writefile({ vim.json.encode(decoded) }, path)
end

local function bodies_in(root, relative)
  local store = require("contextmark.store")
  local result = {}
  for _, comment in ipairs(store.list(root, relative)) do
    result[#result + 1] = comment.body
  end
  table.sort(result)
  return result
end

test("keeps notes another instance wrote to the same sidecar", function()
  local root, store = fixture({ ["docs/a.md"] = { "hello", "world" } })
  add_note(root, "docs/a.md", 1, 1, "mine")
  other_instance_adds(root, "from the other window")

  -- Saving from this instance used to write the whole cached copy back, which
  -- silently deleted whatever the other window had added.
  add_note(root, "docs/a.md", 2, 2, "mine too")
  equal(bodies_in(root, "docs/a.md"), { "from the other window", "mine", "mine too" })

  -- Same situation, but with an unsaved local edit in hand: reloading would
  -- throw our edit away, so this path has to merge instead.
  store.set_fingerprint(root, "docs/a.md", { digest = "local-only", sample = {} })
  other_instance_adds(root, "second other window note")
  equal(store.save(root), true)
  equal(bodies_in(root, "docs/a.md"), {
    "from the other window",
    "mine",
    "mine too",
    "second other window note",
  })
  equal(store.fingerprint(root, "docs/a.md").digest, "local-only")
end)

test("does not resurrect a deleted note when merging", function()
  local root, store = fixture({ ["docs/a.md"] = { "hello", "world" } })
  add_note(root, "docs/a.md", 1, 1, "mine")
  other_instance_adds(root, "doomed note")

  -- Pick the other window's note up, delete it here, then have the other window
  -- write its copy again before our next save.
  local doomed
  for _, comment in ipairs(store.list(root, "docs/a.md")) do
    if comment.body == "doomed note" then
      doomed = comment.id
    end
  end
  assert(doomed, "the other window's note was never loaded")
  equal(store.remove(root, doomed), true)

  local path = store.path(root)
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  decoded.comments[#decoded.comments + 1] = {
    id = doomed,
    file = "docs/a.md",
    filetype = "markdown",
    body = "doomed note",
    created_at = "2026-01-01T00:00:00Z",
    updated_at = "2026-01-01T00:00:00Z",
    anchor = { start_line = 2, end_line = 2, excerpt = { "world" }, status = "exact" },
  }
  vim.fn.writefile({ vim.json.encode(decoded) }, path)

  store.set_fingerprint(root, "docs/a.md", { digest = "force-a-merge", sample = {} })
  equal(store.save(root), true)
  equal(bodies_in(root, "docs/a.md"), { "mine" })
end)

test("adopts notes from a sidecar whose project root moved", function()
  local root, store, util = fixture({ ["docs/a.md"] = { "hello", "world" } })
  local plugin = require("contextmark")
  local now = util.now()
  local gone = vim.fn.tempname() .. "/moved-away"
  equal(
    store.add(gone, {
      id = "cm-adopt-1",
      file = "docs/a.md",
      filetype = "markdown",
      body = "note from the old location",
      created_at = now,
      updated_at = now,
      anchor = {
        kind = "line",
        start_line = 1,
        end_line = 1,
        start_col = 0,
        end_col = 5,
        excerpt = { "hello" },
        before = {},
        after = { "world" },
        status = "exact",
      },
    }),
    true
  )

  vim.cmd.edit(root .. "/docs/a.md")
  local candidates = store.adoptable(root)
  with_select(function(items, _, on_choice)
    on_choice(items[1])
  end, plugin.adopt)
  local adopted = store.list(root, "docs/a.md")
  vim.cmd.enew({ bang = true })

  equal(#candidates, 1)
  equal(candidates[1].root, gone)
  equal(candidates[1].missing, true)
  equal(candidates[1].count, 1)
  equal(#adopted, 1)
  equal(adopted[1].body, "note from the old location")
  -- Adoption is additive: the source sidecar must survive so it can be redone.
  equal(vim.fn.filereadable(candidates[1].path), 1)
end)

test("leaves a live unrelated project's sidecar alone", function()
  local root, store = fixture({ ["docs/a.md"] = { "hello" } })
  local util = require("contextmark.util")
  local other = vim.fn.tempname()
  vim.fn.mkdir(other .. "/.git", "p")
  local now = util.now()
  equal(
    store.add(util.normalize(other), {
      id = "cm-other-1",
      file = "docs/other.md",
      filetype = "markdown",
      body = "belongs elsewhere",
      created_at = now,
      updated_at = now,
      anchor = { start_line = 1, end_line = 1, excerpt = { "x" }, status = "exact" },
    }),
    true
  )

  equal(#store.adoptable(root), 0)
end)

test("moves notes to a new path on request", function()
  local root, store = fixture({ ["docs/a.md"] = { "# Doc", "intro", "- [ ] item", "tail" } })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", 3, 3)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/b.md"), 0)

  vim.cmd.edit(root .. "/docs/b.md")
  plugin.move("docs/a.md", "docs/b.md")
  local render = require("contextmark.render")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, render.namespace(), 0, -1, {})
  vim.cmd.enew({ bang = true })

  equal(#store.list(root, "docs/a.md"), 0)
  equal(#store.list(root, "docs/b.md"), 1)
  equal(store.list(root, "docs/b.md")[1].anchor.status, "exact")
  equal(#marks, 1)
  -- The file's identity has to travel with the notes, or the next replacement
  -- of the new path goes undetected.
  equal(store.fingerprint(root, "docs/a.md"), nil)
  assert(store.fingerprint(root, "docs/b.md"), "the identity did not follow the notes")
end)

test("finds where a renamed file went by its recorded identity", function()
  local root, store = fixture({
    ["docs/a.md"] = {
      "# Design doc",
      "paragraph one",
      "paragraph two",
      "- [ ] item",
      "paragraph three",
    },
    ["docs/decoy.md"] = { "# Something else", "unrelated" },
  })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", 4, 4)
  equal(vim.fn.rename(root .. "/docs/a.md", root .. "/docs/renamed.md"), 0)

  vim.cmd.edit(root .. "/docs/renamed.md")
  local chosen, offered
  with_select(function(items, _, on_choice)
    chosen, offered = items[1], #items
    on_choice(items[1])
  end, plugin.relocate)
  vim.cmd.enew({ bang = true })

  -- Only the file that actually matches the recorded identity may be offered;
  -- the decoy must not appear.
  equal(offered, 1)
  equal(chosen, { from = "docs/a.md", to = "docs/renamed.md" })
  equal(#store.list(root, "docs/a.md"), 0)
  equal(#store.list(root, "docs/renamed.md"), 1)
end)

test("follows a rename made inside the editor", function()
  local root, store = fixture({ ["docs/a.md"] = { "# Doc", "intro", "- [ ] item", "tail" } })
  add_note(root, "docs/a.md", 3, 3)

  vim.cmd.edit(root .. "/docs/a.md")
  -- :saveas leaves the original in place, so the notes must stay with it.
  vim.cmd.saveas(root .. "/docs/copy.md")
  local after_copy = #store.list(root, "docs/a.md")

  -- Once the original is gone the buffer's notes follow it, which is what an
  -- LSP rename looks like: write the new name, then delete the old file.
  equal(vim.fn.delete(root .. "/docs/a.md"), 0)
  vim.cmd.write()
  local moved = #store.list(root, "docs/copy.md")
  vim.cmd.enew({ bang = true })

  equal(after_copy, 1)
  equal(moved, 1)
  equal(#store.list(root, "docs/a.md"), 0)
end)

test("re-anchors a mismatch the author accepts", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", marked_at, marked_at)
  -- A wholesale rewrite is indistinguishable from a replacement, so it is
  -- flagged; only the author can say it was deliberate.
  vim.fn.writefile(document("Gamma"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local flagged = store.list(root, "docs/a.md")[1].anchor.status

  with_select(function(_, _, on_choice)
    on_choice("Accept this file")
  end, plugin.reanchor)
  render.render(bufnr)
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  local rewritten = document("Gamma")
  equal(flagged, "mismatch")
  equal(comment.anchor.status, "exact")
  equal(comment.anchor.before, { rewritten[1], rewritten[2] })
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

  -- The dot in "markdown.mdx" must be escaped, so "markdown*" may not match
  -- an unrelated filetype that merely shares the prefix characters.
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

test("does not accuse a file whose lines were only reformatted", function()
  local identity = require("contextmark.identity")
  local original = document("Alpha")
  local baseline = identity.fingerprint(original)

  -- Trailing whitespace removal on save rewrites every line of a file without
  -- changing a word of it. Flagging that would fire on every save for anyone
  -- with format-on-save enabled.
  local stripped = {}
  for index, line in ipairs(original) do
    stripped[index] = line == "" and "" or (line .. "   ")
  end
  equal(select(1, identity.compare(baseline, stripped)), "same")

  -- The same holds for a re-indent.
  local indented = {}
  for index, line in ipairs(original) do
    indented[index] = line == "" and "" or ("    " .. line)
  end
  equal(select(1, identity.compare(baseline, indented)), "same")
end)

test("does not accuse a file the author rewrote in bulk", function()
  local identity = require("contextmark.identity")
  local original = document("Alpha")
  local baseline = identity.fingerprint(original)

  -- Two thirds of the prose replaced in one sitting is ordinary writing, not a
  -- different document.
  local rewritten = document("Alpha")
  for index = 1, #rewritten do
    if index % 3 ~= 0 and rewritten[index] ~= "" and index ~= marked_at then
      rewritten[index] = "completely new sentence " .. index
    end
  end
  equal(select(1, identity.compare(baseline, rewritten)), "same")
end)

test("recovers a stale note by following the edit on save", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, marked_at - 1, marked_at, false, { "- [x] shipped it" })

  -- Looking at another buffer and coming back used to decide the outcome: the
  -- intervening render marked the note stale, and a stale note was then frozen
  -- so it never followed the edit.
  render.render(bufnr)
  local before_save = store.list(root, "docs/a.md")[1].anchor.status
  render.sync(bufnr)
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  equal(before_save, "stale")
  equal(comment.anchor.status, "exact")
  equal(comment.anchor.excerpt, { "- [x] shipped it" })
end)

test("keeps the excerpt of a note whose text was deleted", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  -- Delete the noted line. The extmark collapses onto nothing, and recapturing
  -- would store an empty excerpt that tells nobody what the note was for.
  vim.api.nvim_buf_set_lines(bufnr, marked_at - 1, marked_at, false, {})
  render.sync(bufnr)
  local comment = store.list(root, "docs/a.md")[1]
  local text = prompt.build(root, { comment })
  vim.cmd.enew({ bang = true })

  equal(comment.anchor.excerpt, { marked_line })
  equal(comment.anchor.status, "stale")
  assert(text:find("> " .. marked_line, 1, true), "the prompt lost the stored excerpt")
  assert(text:find("Status: unresolved", 1, true), "the prompt carried no status")
end)

test("lets a stale rename intent expire instead of firing later", function()
  local root, store = fixture({
    ["docs/spec.md"] = document("Alpha"),
    ["docs/draft.md"] = document("Beta"),
  })
  add_note(root, "docs/spec.md", marked_at, marked_at, "spec note")
  add_note(root, "docs/draft.md", marked_at, marked_at, "draft note")

  vim.cmd.edit(root .. "/docs/spec.md")
  -- :file renames the buffer only. spec.md is still on disk, so nothing moves.
  vim.cmd.file(root .. "/docs/draft.md")
  local after_rename = #store.list(root, "docs/spec.md")

  -- Much later, something unrelated removes spec.md. Coming back to this buffer
  -- must not be read as the rename finally completing.
  equal(vim.fn.delete(root .. "/docs/spec.md"), 0)
  local real_hrtime = vim.uv.hrtime
  vim.uv.hrtime = function()
    return real_hrtime() + 120 * 1000 * 1000 * 1000
  end
  local ok, failure = pcall(vim.cmd.doautocmd, "BufEnter")
  vim.uv.hrtime = real_hrtime
  assert(ok, failure)
  local spec_notes = #store.list(root, "docs/spec.md")
  local draft_notes = #store.list(root, "docs/draft.md")
  vim.cmd.enew({ bang = true })

  equal(after_rename, 1)
  equal(spec_notes, 1)
  equal(draft_notes, 1)
end)

test("refuses to move notes outside the project root", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", marked_at, marked_at)
  vim.cmd.edit(root .. "/docs/a.md")

  plugin.move("docs/a.md", "../escaped.md")
  local escaped = #store.list(root, "docs/a.md")
  vim.cmd.enew({ bang = true })

  equal(escaped, 1)
end)

test("refuses to move a file onto itself", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", marked_at, marked_at)
  vim.fn.writefile(document("Beta"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local flagged = store.list(root, "docs/a.md")[1].anchor.status

  -- A typo like this used to drop the file's identity, and the next render then
  -- adopted the replacement as the note's own file with no warning left.
  plugin.move("docs/a.md", "docs/a.md")
  render.render(bufnr)
  local after = store.list(root, "docs/a.md")[1].anchor.status
  vim.cmd.enew({ bang = true })

  equal(flagged, "mismatch")
  equal(after, "mismatch")
end)

test("keeps the destination's own identity when moving notes onto it", function()
  local root, store = fixture({
    ["docs/a.md"] = document("Alpha"),
    ["docs/b.md"] = document("Beta"),
  })
  add_note(root, "docs/a.md", marked_at, marked_at, "from a")
  add_note(root, "docs/b.md", marked_at, marked_at, "from b")
  local destination = store.fingerprint(root, "docs/b.md")

  equal(select(1, store.rekey(root, "docs/a.md", "docs/b.md")), true)

  -- Overwriting it would flag b.md's own notes as belonging to another file.
  equal(store.fingerprint(root, "docs/b.md"), destination)
  equal(#store.list(root, "docs/b.md"), 2)
end)

test("refuses to re-anchor against an unsaved buffer", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", marked_at, marked_at)
  vim.fn.writefile(document("Gamma"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "# half typed" })

  local asked = false
  with_select(function()
    asked = true
  end, plugin.reanchor)
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  -- Accepting text that is not on disk yet cannot be undone.
  equal(asked, false)
  equal(comment.anchor.excerpt, { marked_line })
end)

test("keeps reading the sidecar after an edit that found no note", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at, "mine")

  -- A note another instance already deleted: the update misses.
  local missing = {
    id = "cm-not-here",
    file = "docs/a.md",
    filetype = "markdown",
    body = "gone",
    anchor = { start_line = 1, end_line = 1, excerpt = { "x" }, status = "exact" },
  }
  equal(select(1, store.update(root, missing)), false)

  -- The failed update must not leave the cache marked dirty, or this instance
  -- stops reloading and its next save rolls back the other one's work.
  other_instance_adds(root, "from the other window")
  equal(bodies_in(root, "docs/a.md"), { "from the other window", "mine" })
end)

test("refuses to save while another instance holds the lock", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  local lock = store.path(root) .. ".lock"

  local handle = assert(vim.uv.fs_open(lock, "wx", 384), "could not take the lock")
  vim.uv.fs_close(handle)
  store.set_fingerprint(root, "docs/a.md", { digest = "local-only", sample = {} })
  local blocked, reason = store.save(root)

  -- A lock left behind by a crashed instance must not block writes forever.
  local stale = os.time() - 600
  vim.uv.fs_utime(lock, stale, stale)
  local reclaimed = store.save(root)
  vim.uv.fs_unlink(lock)

  equal(blocked, false)
  assert(reason and reason:find("locked", 1, true), "the reason did not mention the lock")
  equal(reclaimed, true)
end)

test("does not match an unrelated file through a repeated line", function()
  local identity = require("contextmark.identity")
  -- A table or a command list repeats the same row many times. If the sample
  -- keeps duplicates it fills up with that one row, and any other file that
  -- happens to contain it then looks like the same document.
  local page = { "# Commands" }
  for index = 1, 15 do
    page[#page + 1] = ("| command %d | does thing %d |"):format(index, index)
  end
  for _ = 1, 40 do
    page[#page + 1] = "| run | starts the thing |"
  end
  local baseline = identity.fingerprint(page)

  local unrelated = { "# Something else entirely", "| run | starts the thing |" }
  for index = 1, 20 do
    unrelated[#unrelated + 1] = "prose about a different subject " .. index
  end
  equal(select(1, identity.compare(baseline, unrelated)), "replaced")
end)

test("falls back to the stored excerpt when the file has nothing there", function()
  local util = require("contextmark.util")
  local original_reader = util.read_buffer_or_file
  util.read_buffer_or_file = function()
    return { "first line", "", "third line" }
  end
  local text = prompt.build("/project", {
    {
      file = "note.md",
      filetype = "markdown",
      body = "keep this",
      -- A healthy status whose range now covers a blank line. Nothing warns
      -- here, so without the fallback the agent receives a bare ">".
      anchor = {
        start_line = 2,
        end_line = 2,
        start_col = 0,
        end_col = 0,
        excerpt = { "the noted sentence" },
        status = "exact",
      },
    },
  })
  util.read_buffer_or_file = original_reader
  assert(text:find("> the noted sentence", 1, true), "the stored excerpt was not used")
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
  -- cquit takes the exit code as a count. Passing it positionally raises
  -- "Wrong number of arguments", which replaced the failure count with a Lua
  -- traceback on every red run.
  vim.cmd.cquit({ count = failures })
end
print(("%d tests passed"):format(#tests))
