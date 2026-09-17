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
  local text = prompt.build(root, { comment })
  equal(comment.anchor.status, "mismatch")
  -- The stored position stays where the note actually was. Adopting the
  -- impostor's line number would make the prompt quote the original text under
  -- this file's coordinates, and would throw away the last record of the note's
  -- own place in its file.
  equal(comment.anchor.start_line, marked_at)
  assert(text:find("Line " .. marked_at .. "\n", 1, true), "the prompt moved the note")
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
  local blank_only = {}
  for index = 1, 14 do
    blank_only[index] = index % 2 == 0 and "" or "   "
  end
  equal(select(1, identity.compare(identity.fingerprint(blank_only), { "x" })), "unknown")

  -- A document too short to judge is left alone in both directions. Accusing on
  -- a handful of lines is guesswork, and it used to make :ContextMarkRelocate
  -- offer every short file as a candidate for every other one.
  local tiny = identity.fingerprint({ "only line" })
  equal(select(1, identity.compare(tiny, { "only line", "added" })), "unknown")
  equal(select(1, identity.compare(tiny, { "something else" })), "unknown")
end)

test("samples the whole document, not just its opening", function()
  local identity = require("contextmark.identity")
  -- 60 significant lines. A stepped walk used to spend the whole sample inside
  -- the first 32 of them, so everything after that carried no weight at all.
  local body = {}
  for index = 1, 60 do
    body[index] = "paragraph " .. index .. " of the original document"
  end
  local baseline = identity.fingerprint(body)

  -- Rewriting the opening half is ordinary editing, and with the sample spread
  -- across the document the untouched half still speaks for it.
  local front_rewritten = vim.deepcopy(body)
  for index = 1, 31 do
    front_rewritten[index] = "rewritten opening " .. index
  end
  equal(select(1, identity.compare(baseline, front_rewritten)), "same")

  -- The same has to hold for the other end of the file.
  local tail_rewritten = vim.deepcopy(body)
  for index = 30, 60 do
    tail_rewritten[index] = "rewritten ending " .. index
  end
  equal(select(1, identity.compare(baseline, tail_rewritten)), "same")

  -- And a genuinely different document is still caught.
  local unrelated = {}
  for index = 1, 60 do
    unrelated[index] = "a completely unrelated sentence " .. index
  end
  equal(select(1, identity.compare(baseline, unrelated)), "replaced")
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
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
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
  -- An emptied file loses every line, which reads as a replacement. It is not
  -- one: reporting "different file?" for a file the author just cleared would
  -- be wrong, and the sign has to stay the unresolved one.
  equal(#extmarks, 1)
  equal(extmarks[1][4].sign_text, "? ")
  equal(comment.anchor.status, "orphaned")
  equal(comment.anchor.excerpt, { marked_line })
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
  local candidates = plugin.adoption_candidates(root)
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

test("does not adopt a note whose path escapes the project root", function()
  local root, store, util = fixture({ ["docs/a.md"] = { "hello", "world" } })
  local plugin = require("contextmark")
  local now = util.now()
  -- A file right next to the root, which "../" from inside it would reach.
  local outside = vim.fs.basename(root) .. "-outside.md"
  vim.fn.writefile({ "secret" }, vim.fs.dirname(root) .. "/" .. outside)
  local gone = vim.fn.tempname() .. "/moved-away"
  local function note(id, file)
    return {
      id = id,
      file = file,
      filetype = "markdown",
      body = id,
      created_at = now,
      updated_at = now,
      anchor = { kind = "line", start_line = 1, end_line = 1, excerpt = { "hello" } },
    }
  end
  equal(store.add(gone, note("cm-inside", "docs/a.md")), true)
  equal(store.add(gone, note("cm-escape", "../" .. outside)), true)

  local candidates = plugin.adoption_candidates(root)

  equal(#candidates, 1)
  equal(candidates[1].count, 1)
  equal(candidates[1].skipped, 1)
  equal(candidates[1].comments[1].file, "docs/a.md")
end)

test("adoption skips a note that has no id instead of failing", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local ok, added = store.import(root, {
    { file = "docs/a.md", body = "no id", anchor = { start_line = 1, end_line = 1 } },
    {
      id = "cm-good",
      file = "docs/a.md",
      body = "good",
      anchor = { start_line = 1, end_line = 1 },
    },
  }, {})

  equal(ok, true)
  equal(added, 1)
  equal(#store.list(root, "docs/a.md"), 1)
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

  equal(#require("contextmark").adoption_candidates(root), 0)
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
  -- intervening render re-resolved from the sidecar, lost the extmark that had
  -- followed the edit, and marked the note stale. It now keeps the live
  -- position while the buffer is modified.
  render.render(bufnr)
  local before_save = store.list(root, "docs/a.md")[1].anchor.status
  render.sync(bufnr)
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  equal(before_save, "exact")
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
    -- The destination deliberately has no notes of its own, so nothing but the
    -- expiry stands between an unrelated deletion and a wrong move.
    ["docs/draft.md"] = document("Beta"),
  })
  add_note(root, "docs/spec.md", marked_at, marked_at, "spec note")

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
  equal(draft_notes, 0)
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
  local messages = {}
  local original_notify = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  local ok, failure = pcall(plugin.move, "docs/a.md", "docs/a.md")
  vim.notify = original_notify
  if not ok then
    error(failure, 0)
  end
  render.render(bufnr)
  local after = store.list(root, "docs/a.md")[1].anchor.status
  vim.cmd.enew({ bang = true })

  equal(flagged, "mismatch")
  equal(after, "mismatch")
  -- The command must refuse on its own, not report "moved 0 note(s)".
  equal(messages, { "contextmark: the source and destination are the same file" })
end)

test("rekeying a file onto itself keeps its identity", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)

  -- store.rekey() guards this itself, independent of the :ContextMarkMove check.
  local ok, moved = store.rekey(root, "docs/a.md", "docs/a.md")

  equal(ok, true)
  equal(moved, 0)
  assert(store.fingerprint(root, "docs/a.md"), "the file's identity was dropped")
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

test("refuses to re-anchor when the buffer is edited while the prompt is open", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", marked_at, marked_at)
  vim.fn.writefile(document("Gamma"), root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local baseline = store.fingerprint(root, "docs/a.md")

  -- vim.ui.select() may be an asynchronous picker: the buffer can change
  -- between the unsaved-buffer check and the answer.
  with_select(function(_, _, on_choice)
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "# half typed" })
    on_choice("Accept this file")
  end, plugin.reanchor)
  local comment = store.list(root, "docs/a.md")[1]
  local after = store.fingerprint(root, "docs/a.md")
  vim.cmd.enew({ bang = true })

  equal(comment.anchor.excerpt, { marked_line })
  equal(comment.previous_anchor, nil)
  equal(after, baseline)
end)

test("does not take a baseline when a note without one fails to resolve", function()
  local root, store, util = fixture({ ["docs/a.md"] = document("Alpha") })
  local now = util.now()
  -- A note from before fingerprints existed, recorded as healthy.
  equal(
    store.add(root, {
      id = "cm-no-baseline",
      file = "docs/a.md",
      filetype = "markdown",
      body = "written before fingerprints",
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(document("Alpha"), marked_at, marked_at, 2),
    }),
    true
  )
  -- Opened on a different document that lacks the noted line.
  local other = document("Gamma")
  other[marked_at] = "- [ ] something else entirely"
  vim.fn.writefile(other, root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  render.render(vim.api.nvim_get_current_buf())
  local status = store.list(root, "docs/a.md")[1].anchor.status
  local baseline = store.fingerprint(root, "docs/a.md")
  vim.cmd.enew({ bang = true })

  -- Recording this document would make it the note's file for good, and the
  -- real one could never be recognised again.
  assert(util.is_warning_status(status), status)
  equal(baseline, nil)
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

test("refuses to overwrite a sidecar it cannot read", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at, "precious")
  local path = store.path(root)
  local intact = table.concat(vim.fn.readfile(path), "\n")

  -- Truncate the file the way an interrupted write or a full disk would. The
  -- damaged bytes are what has to survive: whether any particular note body is
  -- still inside them depends on JSON key order, which is not deterministic.
  local damaged = intact:sub(1, math.floor(#intact / 2))
  vim.fn.writefile({ damaged }, path)
  store.reset_cache()

  -- Reading it as an empty project and saving over it used to replace every
  -- note in the file with nothing.
  equal(#store.list(root), 0)
  local saved, reason = store.save(root)
  local still_there = table.concat(vim.fn.readfile(path), "\n")

  equal(saved, false)
  assert(reason and reason:find("unreadable", 1, true), "the reason did not explain itself")
  equal(still_there, damaged)

  -- A sidecar from a newer version is refused for the same reason.
  vim.fn.writefile({ vim.json.encode({ version = 99, comments = {} }) }, path)
  store.reset_cache()
  local future_saved, future_reason = store.save(root)
  equal(future_saved, false)
  assert(future_reason and future_reason:find("newer version", 1, true), future_reason)
end)

test("refuses to overwrite a sidecar whose comments field is missing", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at, "precious")
  local path = store.path(root)

  -- Parseable JSON with the right version, but not a shape this version wrote.
  -- Reading it as an empty project let the next save replace the file.
  for _, damaged in ipairs({
    vim.json.encode({ version = 1, root = root }),
    vim.json.encode({ version = 1, root = root, comments = "precious" }),
  }) do
    vim.fn.writefile({ damaged }, path)
    store.reset_cache()
    local saved, reason = store.save(root)
    equal(saved, false)
    assert(reason and reason:find("unreadable", 1, true), reason)
    equal(table.concat(vim.fn.readfile(path), "\n"), damaged)
  end
end)

test("refuses to overwrite a sidecar it has no permission to read", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at, "precious")
  local path = store.path(root)
  local intact = table.concat(vim.fn.readfile(path), "\n")

  -- A file that exists but cannot be opened used to read as an empty project,
  -- and the next save replaced every note in it.
  assert(vim.uv.fs_chmod(path, tonumber("000", 8)))
  store.reset_cache()
  local listed = #store.list(root)
  local saved, reason = store.save(root)
  assert(vim.uv.fs_chmod(path, tonumber("644", 8)))

  equal(listed, 0)
  equal(saved, false)
  assert(reason and reason:find("unreadable", 1, true), reason)
  equal(table.concat(vim.fn.readfile(path), "\n"), intact)
end)

test("survives a note whose anchor is damaged", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at, "healthy")
  local path = store.path(root)
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  decoded.comments[#decoded.comments + 1] = {
    id = "cm-damaged",
    file = "docs/a.md",
    filetype = "markdown",
    body = "the body is still worth keeping",
  }
  vim.fn.writefile({ vim.json.encode(decoded) }, path)
  store.reset_cache()

  -- Listing used to throw on the missing anchor, which broke every command.
  local ok, comments = pcall(store.list, root, "docs/a.md")
  assert(ok, tostring(comments))
  equal(#comments, 2)
  local bodies = { comments[1].body, comments[2].body }
  table.sort(bodies)
  equal(bodies, { "healthy", "the body is still worth keeping" })
end)

test("adopts a sidecar whose files are already in this project", function()
  local root, store, util = fixture({ ["notes/todo.md"] = document("Alpha") })
  local plugin = require("contextmark")
  local now = util.now()

  -- What the previous version wrote for a tree without a repository marker: the
  -- root came from the current directory, so it is a sibling of the root this
  -- version derives, and the notes name files that do exist here.
  local previous_root = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(previous_root, "p")
  equal(
    store.add(previous_root, {
      id = "cm-previous-1",
      file = "notes/todo.md",
      filetype = "markdown",
      body = "written before the upgrade",
      created_at = now,
      updated_at = now,
      anchor = {
        kind = "line",
        start_line = marked_at,
        end_line = marked_at,
        start_col = 0,
        end_col = #marked_line,
        excerpt = { marked_line },
        status = "exact",
      },
    }),
    true
  )

  vim.cmd.edit(root .. "/notes/todo.md")
  local candidates = plugin.adoption_candidates(root)
  with_select(function(items, _, on_choice)
    on_choice(items[1])
  end, plugin.adopt)
  local adopted = store.list(root, "notes/todo.md")
  vim.cmd.enew({ bang = true })

  equal(#candidates, 1)
  equal(candidates[1].count, 1)
  equal(#adopted, 1)
  equal(adopted[1].body, "written before the upgrade")
end)

test("does not adopt by name a note whose path escapes the project root", function()
  local root, store, util = fixture({ ["notes/todo.md"] = document("Alpha") })
  local plugin = require("contextmark")
  local now = util.now()
  -- A file right next to the root, which "../" from inside it would reach.
  local outside = vim.fs.basename(root) .. "-outside.md"
  vim.fn.writefile({ "secret" }, vim.fs.dirname(root) .. "/" .. outside)

  -- A live previous root without .git, somewhere "../" reaches nothing, so the
  -- by-name fallback is the only branch that could accept the key.
  local previous_root = util.normalize(vim.fn.tempname() .. "/deep/previous")
  vim.fn.mkdir(previous_root, "p")
  local function note(id, file)
    return {
      id = id,
      file = file,
      filetype = "markdown",
      body = id,
      created_at = now,
      updated_at = now,
      anchor = { kind = "line", start_line = 1, end_line = 1, excerpt = { marked_line } },
    }
  end
  equal(store.add(previous_root, note("cm-by-name-inside", "notes/todo.md")), true)
  equal(store.add(previous_root, note("cm-by-name-escape", "../" .. outside)), true)

  local candidates = plugin.adoption_candidates(root)

  equal(#candidates, 1)
  equal(candidates[1].count, 1)
  equal(candidates[1].skipped, 1)
  equal(candidates[1].comments[1].file, "notes/todo.md")
end)

test("does not take an unsaved draft as the file's identity", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render(bufnr)
  local baseline = store.fingerprint(root, "docs/a.md")

  -- Append a long draft without saving, then throw it away. The draft is still
  -- recognisably this file, so the baseline would be replaced by text that was
  -- never on disk, and the untouched file would end up flagged against itself.
  local draft = document("Alpha")
  for index = 1, 40 do
    draft[#draft + 1] = "an unsaved paragraph " .. index
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, draft)
  render.render(bufnr)
  local during = store.fingerprint(root, "docs/a.md")
  vim.cmd.edit({ args = { root .. "/docs/a.md" }, bang = true })
  local restored_buffer = vim.api.nvim_get_current_buf()
  render.render(restored_buffer)
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  equal(during, baseline)
  equal(comment.anchor.status, "exact")
end)

test("never names a line the file does not have", function()
  local util = require("contextmark.util")
  local original_reader = util.read_buffer_or_file
  util.read_buffer_or_file = function()
    return { "one", "two", "three" }
  end
  local healthy = prompt.build("/project", {
    {
      file = "note.md",
      filetype = "markdown",
      body = "keep this",
      -- The file was truncated while it was closed, so the stored range is
      -- past its end while the status still says the note resolved.
      anchor = {
        start_line = 38,
        end_line = 39,
        start_col = 0,
        end_col = 0,
        excerpt = { "the noted sentence" },
        status = "exact",
      },
    },
  })
  local flagged = prompt.build("/project", {
    {
      file = "note.md",
      filetype = "markdown",
      body = "keep this",
      anchor = {
        start_line = 38,
        end_line = 39,
        start_col = 0,
        end_col = 0,
        excerpt = { "the noted sentence" },
        status = "mismatch",
      },
    },
  })
  util.read_buffer_or_file = original_reader

  assert(not healthy:find("Lines 38", 1, true), "the prompt named a line past the end of the file")
  assert(not flagged:find("Lines 38", 1, true), "the flagged prompt named a line past the end")
  assert(healthy:find("> the noted sentence", 1, true), "the stored excerpt was dropped")
end)

test("names line 1 for a note on a file that is now empty", function()
  local util = require("contextmark.util")
  local original_reader = util.read_buffer_or_file
  local function build(contents)
    util.read_buffer_or_file = function()
      return contents
    end
    local ok, text = pcall(prompt.build, "/project", {
      {
        file = "note.md",
        filetype = "markdown",
        body = "keep this",
        anchor = {
          start_line = 38,
          end_line = 39,
          excerpt = { "the noted sentence" },
          status = "orphaned",
        },
      },
    })
    util.read_buffer_or_file = original_reader
    if not ok then
      error(text, 0)
    end
    return text
  end

  -- Readable but empty: the same 1-1 that anchor.resolve() gives an empty file.
  local empty = build({})
  -- Unreadable: nothing to clamp against, so the stored range is all we know.
  local unreadable = build(nil)

  assert(empty:find("Line 1\n", 1, true), empty)
  assert(not empty:find("Lines 38", 1, true), "the prompt named a line an empty file lacks")
  assert(empty:find("> the noted sentence", 1, true), "the stored excerpt was dropped")
  assert(unreadable:find("Lines 38-39", 1, true), unreadable)
end)

test("reports a sidecar write that fails part way", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  local path = store.path(root)
  local intact = table.concat(vim.fn.readfile(path), "\n")

  -- A full disk fails at write(), not at open(). Ignoring that reported success
  -- while leaving a truncated file where the notes used to be.
  local original_open = io.open
  io.open = function(target, mode)
    if mode == "w" then
      return {
        write = function()
          return nil, "no space left on device"
        end,
        close = function()
          return true
        end,
      }
    end
    return original_open(target, mode)
  end
  store.set_fingerprint(root, "docs/a.md", { digest = "forces-a-write", sample = {} })
  local ok, reason = store.save(root)
  io.open = original_open

  equal(ok, false)
  assert(reason and reason:find("no space", 1, true), tostring(reason))
  -- The sidecar that was already there must be untouched.
  equal(table.concat(vim.fn.readfile(path), "\n"), intact)
end)

test("leaves a rename alone when the destination already has notes", function()
  local root, store = fixture({
    ["docs/spec.md"] = document("Alpha"),
    ["docs/draft.md"] = document("Beta"),
  })
  add_note(root, "docs/spec.md", marked_at, marked_at, "spec note")
  add_note(root, "docs/draft.md", marked_at, marked_at, "draft note")

  vim.cmd.edit(root .. "/docs/spec.md")
  vim.cmd.file(root .. "/docs/draft.md")
  -- The original disappears while the rename intent is still fresh, so only the
  -- destination check stands between this and two files' notes being merged.
  equal(vim.fn.delete(root .. "/docs/spec.md"), 0)
  local ok, failure = pcall(vim.cmd.doautocmd, "BufEnter")
  assert(ok, failure)
  local spec_notes = #store.list(root, "docs/spec.md")
  local draft_notes = store.list(root, "docs/draft.md")
  vim.cmd.enew({ bang = true })

  equal(spec_notes, 1)
  equal(#draft_notes, 1)
  equal(draft_notes[1].body, "draft note")
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

-- A second Neovim instance: its own copy of the store's module state, reading and
-- writing the same sidecar directory. Restores this instance's module afterwards.
local function with_other_instance(body)
  local mine = package.loaded["contextmark.store"]
  package.loaded["contextmark.store"] = nil
  local ok, failure = pcall(body, require("contextmark.store"))
  package.loaded["contextmark.store"] = mine
  if not ok then
    error(failure, 0)
  end
end

local function plain_note(id, body)
  return {
    id = id,
    file = "note.md",
    body = body or id,
    created_at = id,
    anchor = { start_line = 1, end_line = 1 },
  }
end

test("keeps another instance's edits and deletions after a failed save", function()
  local root, store = fixture({ ["note.md"] = { "hello" } })
  equal(store.add(root, plain_note("cm-x", "old")), true)
  equal(store.add(root, plain_note("cm-z")), true)

  -- A save that fails (here: the sidecar is locked) used to pin the cache, so
  -- this instance never saw later changes and its next save wrote them away.
  local lock = store.path(root) .. ".lock"
  vim.fn.writefile({}, lock)
  local locked = store.add(root, plain_note("cm-a1"))
  vim.uv.fs_unlink(lock)
  equal(locked, false)

  with_other_instance(function(other)
    local x = vim.deepcopy(other.list(root)[1])
    x.body = "new from the other instance"
    equal(other.update(root, x), true)
    equal(other.remove(root, "cm-z"), true)
  end)

  equal(store.add(root, plain_note("cm-a2")), true)
  local bodies = {}
  with_other_instance(function(other)
    for _, comment in ipairs(other.list(root)) do
      bodies[comment.id] = comment.body
    end
  end)
  equal(bodies, {
    ["cm-a1"] = "cm-a1",
    ["cm-a2"] = "cm-a2",
    ["cm-x"] = "new from the other instance",
  })
end)

test("refuses to overwrite a sidecar that became unreadable after a failed save", function()
  local root, store = fixture({ ["note.md"] = { "hello" } })
  equal(store.add(root, plain_note("cm-x")), true)
  local lock = store.path(root) .. ".lock"
  vim.fn.writefile({}, lock)
  equal(store.add(root, plain_note("cm-a1")), false)
  vim.uv.fs_unlink(lock)

  -- A newer contextmark rewrote the sidecar in the meantime.
  local newer = vim.json.encode({ version = 2, root = root, notes = { { id = "v2" } } })
  vim.fn.writefile({ newer }, store.path(root))

  local ok = store.add(root, plain_note("cm-a2"))
  equal(ok, false)
  equal(vim.fn.readfile(store.path(root)), { newer })
end)

test("does not bring back a deleted legacy note when the migration save failed", function()
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

  local legacy_root = vim.fs.normalize(base .. "/link")
  local root = util.project_root(base .. "/real/note.md")
  local encoded =
    vim.json.encode({ version = 1, root = legacy_root, comments = { plain_note("cm-legacy") } })
  vim.fn.writefile({ encoded }, store.path(legacy_root))

  -- The save attempted during migration fails, so the legacy file stays.
  local lock = store.path(root) .. ".lock"
  vim.fn.writefile({}, lock)
  equal(#store.list(root), 1)
  vim.uv.fs_unlink(lock)
  equal(vim.uv.fs_stat(store.path(legacy_root)) ~= nil, true)

  -- The first save that does succeed must retire it, or the next session merges
  -- the deleted note back in.
  equal(store.remove(root, "cm-legacy"), true)
  equal(vim.uv.fs_stat(store.path(legacy_root)), nil)
  store.reset_cache()
  equal(#store.list(root), 0)

  store.reset_cache()
  vim.fn.delete(base, "rf")
end)

test("sends an unresolved note with its stored excerpt, not the text now at its line", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha"), ["docs/z.md"] = { "z" } })
  local noted_at = 7
  add_note(root, "docs/a.md", noted_at, noted_at, "fix wording")
  local original = store.list(root, "docs/a.md")[1].anchor.excerpt

  -- Edited while closed: two lines added on top, and the noted line reworded.
  local edited = document("Alpha")
  edited[noted_at] = "Alpha second heading"
  table.insert(edited, 1, "intro")
  table.insert(edited, 2, "")
  vim.fn.writefile(edited, root .. "/docs/a.md")

  local plugin = require("contextmark")
  vim.cmd.edit(root .. "/docs/a.md")
  local rendered = store.list(root, "docs/a.md")[1].anchor.status
  -- Send runs sync_all, which used to recapture the fallback line as "exact".
  local text = plugin.build_prompt("all")
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  equal(rendered, "stale")
  equal(comment.anchor.status, "stale")
  equal(comment.anchor.excerpt, original)
  assert(text:find("Status: unresolved", 1, true), "the prompt carried no status")
  assert(text:find("> " .. original[1], 1, true), "the prompt lost the stored excerpt")
end)

test("keeps a mismatched note's recorded line through a send", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  local impostor = document("Beta")
  impostor[marked_at] = "Beta heading 1"
  impostor[40] = marked_line
  vim.fn.writefile(impostor, root .. "/docs/a.md")

  local plugin = require("contextmark")
  vim.cmd.edit(root .. "/docs/a.md")
  -- Unlike prompt.build(), build_prompt() syncs the open buffer first. Syncing
  -- used to copy the extmark's line -- the impostor's match -- into the sidecar.
  local text = plugin.build_prompt("all")
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  equal(comment.anchor.status, "mismatch")
  equal(comment.anchor.start_line, marked_at)
  assert(text:find("Line " .. marked_at .. "\n", 1, true), "the prompt moved the note")
end)

test("re-keys a note recorded under a symlinked file in the same project", function()
  local root, store = fixture({ ["docs/real.md"] = document("Alpha") })
  assert(vim.uv.fs_symlink(root .. "/docs/real.md", root .. "/docs/alias.md"))
  local util = require("contextmark.util")
  local now = util.now()
  -- What the previous version stored when the file was opened through the link.
  equal(
    store.add(root, {
      id = "cm-alias",
      file = "docs/alias.md",
      filetype = "markdown",
      body = "written through the link",
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(document("Alpha"), marked_at, marked_at, 2),
    }),
    true
  )

  vim.cmd.edit(root .. "/docs/real.md")
  local bufnr = vim.api.nvim_get_current_buf()
  local extmarks =
    vim.api.nvim_buf_get_extmarks(bufnr, require("contextmark.render").namespace(), 0, -1, {})
  local notes = store.list(root, "docs/real.md")
  vim.cmd.enew({ bang = true })

  equal(#notes, 1)
  equal(notes[1].body, "written through the link")
  equal(#store.list(root, "docs/alias.md"), 0)
  equal(#extmarks, 1)
end)

test("retries a failed re-key and reports the failure once", function()
  local root, store = fixture({ ["docs/real.md"] = document("Alpha") })
  assert(vim.uv.fs_symlink(root .. "/docs/real.md", root .. "/docs/alias.md"))
  local util = require("contextmark.util")
  local now = util.now()
  equal(
    store.add(root, {
      id = "cm-alias-retry",
      file = "docs/alias.md",
      filetype = "markdown",
      body = "written through the link",
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(document("Alpha"), marked_at, marked_at, 2),
    }),
    true
  )

  local original_rekey, original_notify = store.rekey, vim.notify
  local errors = 0
  store.rekey = function()
    return false, 0, "sidecar is locked by another Neovim instance"
  end
  vim.notify = function(message, level)
    if level == vim.log.levels.ERROR and message:find("could not save", 1, true) then
      errors = errors + 1
    end
  end
  local ok, failure = pcall(function()
    vim.cmd.edit(root .. "/docs/real.md")
    vim.cmd.doautocmd("BufEnter")
    vim.cmd.doautocmd("BufEnter")
  end)
  store.rekey, vim.notify = original_rekey, original_notify
  if not ok then
    vim.cmd.enew({ bang = true })
    error(failure, 0)
  end
  local while_locked = #store.list(root, "docs/real.md")

  -- Once the lock is gone, the next BufEnter must finish the job.
  vim.cmd.doautocmd("BufEnter")
  local after = #store.list(root, "docs/real.md")
  vim.cmd.enew({ bang = true })

  equal(errors, 1)
  equal(while_locked, 0)
  equal(after, 1)
end)

test("does not offer a live project's notes because a file name also exists here", function()
  local root, store, util = fixture({ ["README.md"] = document("Mine") })
  local other = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(other .. "/.git", "p")
  vim.fn.writefile(document("Other"), other .. "/README.md")
  local now = util.now()
  equal(
    store.add(other, {
      id = "cm-other-readme",
      file = "README.md",
      filetype = "markdown",
      body = "belongs to the other project",
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(document("Other"), marked_at, marked_at, 2),
    }),
    true
  )

  equal(#require("contextmark").adoption_candidates(root), 0)
end)

test("does not offer projects below a loose file's directory", function()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/develop/proj/.git", "p")
  vim.fn.writefile({ "# todo" }, base .. "/todo.md")
  vim.fn.writefile(document("Proj"), base .. "/develop/proj/README.md")
  local store = require("contextmark.store")
  local util = require("contextmark.util")
  store.reset_cache()
  require("contextmark").setup({ storage = { dir = vim.fn.tempname() } })
  local project = util.project_root(base .. "/develop/proj/README.md")
  local loose = util.project_root(base .. "/todo.md")
  local now = util.now()
  equal(
    store.add(project, {
      id = "cm-proj",
      file = "README.md",
      filetype = "markdown",
      body = "project note",
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(document("Proj"), marked_at, marked_at, 2),
    }),
    true
  )

  -- The loose file's root is an ancestor of the project. The project's notes
  -- still belong to the project, not to that ancestor.
  equal(#require("contextmark").adoption_candidates(loose), 0)
  vim.fn.delete(base, "rf")
end)

-- Runs `between` after save() has loaded the cache but before it takes the lock:
-- the window where only the re-check inside the lock can see another writer.
local function between_load_and_lock(between, body)
  local original = vim.fn.mkdir
  local fired = false
  vim.fn.mkdir = function(...)
    if not fired then
      fired = true
      between()
    end
    return original(...)
  end
  local ok, failure = pcall(body)
  vim.fn.mkdir = original
  if not ok then
    error(failure, 0)
  end
end

test("merges a write that lands between loading and locking", function()
  local root, store = fixture({ ["note.md"] = { "hello" } })
  equal(store.add(root, plain_note("cm-x", "old")), true)
  between_load_and_lock(function()
    with_other_instance(function(other)
      local x = vim.deepcopy(other.list(root)[1])
      x.body = "edited in the gap"
      equal(other.update(root, x), true)
    end)
  end, function()
    equal(store.add(root, plain_note("cm-a")), true)
  end)

  local bodies = {}
  with_other_instance(function(other)
    for _, comment in ipairs(other.list(root)) do
      bodies[comment.id] = comment.body
    end
  end)
  equal(bodies, { ["cm-a"] = "cm-a", ["cm-x"] = "edited in the gap" })
end)

test("refuses a sidecar that became unreadable between loading and locking", function()
  local root, store = fixture({ ["note.md"] = { "hello" } })
  equal(store.add(root, plain_note("cm-x")), true)
  local newer = vim.json.encode({ version = 2, root = root, notes = { { id = "v2" } } })
  between_load_and_lock(function()
    vim.fn.writefile({ newer }, store.path(root))
  end, function()
    equal(store.add(root, plain_note("cm-a")), false)
  end)
  equal(vim.fn.readfile(store.path(root)), { newer })
end)

test("adopts notes whose root is now derived one level down", function()
  local root, store, util = fixture({ ["docs/a.md"] = document("Alpha") })
  -- The same files, recorded under a root above this one: only the way the root
  -- is derived changed, so each key has to be re-based, not kept.
  local parent = vim.fs.dirname(root)
  local leaf = vim.fs.basename(root)
  local now = util.now()
  equal(
    store.add(parent, {
      id = "cm-parent",
      file = leaf .. "/docs/a.md",
      filetype = "markdown",
      body = "recorded from above",
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(document("Alpha"), marked_at, marked_at, 2),
    }),
    true
  )

  local candidates = require("contextmark").adoption_candidates(root)
  equal(#candidates, 1)
  equal(candidates[1].comments[1].file, "docs/a.md")
end)

test("does not match a live repository's notes by name", function()
  local root, store, util = fixture({ ["README.md"] = document("Mine") })
  -- A project with .git never keyed files by bare name, so its README.md note is
  -- not this project's README.md even after its own copy was deleted.
  local other = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(other .. "/.git", "p")
  local now = util.now()
  equal(
    store.add(other, {
      id = "cm-other-readme",
      file = "README.md",
      filetype = "markdown",
      body = "belongs to the other project",
      created_at = now,
      updated_at = now,
      anchor = anchor.capture(document("Other"), marked_at, marked_at, 2),
    }),
    true
  )

  equal(#require("contextmark").adoption_candidates(root), 0)
end)

test("keeps a mismatched note's line past the end of a shorter replacement", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local noted_at = 50
  add_note(root, "docs/a.md", noted_at, noted_at)
  local impostor = vim.list_slice(document("Beta"), 1, 30)
  vim.fn.writefile(impostor, root .. "/docs/a.md")

  local render = require("contextmark.render")
  vim.cmd.edit(root .. "/docs/a.md")
  render.render(vim.api.nvim_get_current_buf())
  local comment = store.list(root, "docs/a.md")[1]
  vim.cmd.enew({ bang = true })

  equal(comment.anchor.status, "mismatch")
  -- Clamped for display only. Writing the clamped line back would lose where
  -- the note was in its own file.
  equal(comment.anchor.start_line, noted_at)
end)

test("keys a file whose name contains $VAR literally", function()
  local name = "docs/cost$HOME.md"
  local root, _, util = fixture({ [name] = document("Alpha") })
  local path = root .. "/" .. name

  -- vim.fs.normalize() expands environment variables by default, which turned
  -- this key into "docs/cost/Users/<user>.md": no buffer or file matched it.
  equal(util.relative_path(path, root), name)
  equal(util.absolute_path(root, name), path)
  equal(vim.fn.filereadable(util.absolute_path(root, name)), 1)
end)

test("moves and adopts notes on a symlink that points outside the project", function()
  local root, store, util = fixture({ ["notes/todo.md"] = document("Alpha") })
  local plugin = require("contextmark")
  local outside = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile(document("Linked"), outside .. "/x.md")
  assert(vim.uv.fs_symlink(outside .. "/x.md", root .. "/notes/alias.md"))

  -- The link is keyed inside the project, as "notes/alias.md".
  add_note(root, "notes/alias.md", marked_at, marked_at, "on the link")
  vim.cmd.edit(root .. "/notes/todo.md")
  plugin.move("notes/alias.md", "notes/renamed.md")
  local moved = #store.list(root, "notes/renamed.md")

  -- A project that moved away wholesale, with a note on the same link key.
  local gone = vim.fn.tempname() .. "/moved-away"
  local now = util.now()
  equal(
    store.add(gone, {
      id = "cm-link-adopt",
      file = "notes/alias.md",
      filetype = "markdown",
      body = "adopt me",
      created_at = now,
      updated_at = now,
      anchor = { kind = "line", start_line = 1, end_line = 1, excerpt = { "# Linked" } },
    }),
    true
  )
  local candidates = plugin.adoption_candidates(root)
  vim.cmd.enew({ bang = true })

  -- Both used to resolve the key through the link to a path outside the root
  -- and give up with "both paths must be inside".
  equal(moved, 1)
  equal(#candidates, 1)
  equal(candidates[1].comments[1].file, "notes/alias.md")
end)

test("an edit saved late does not undo a move made meanwhile", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at, "before")

  -- M.edit() holds the note while the float waits for input. A reload from
  -- disk replaces the cached tables, so what it holds is a copy.
  local held = vim.deepcopy(store.list(root, "docs/a.md")[1])
  local ok = store.rekey(root, "docs/a.md", "docs/b.md")
  equal(ok, true)

  held.body = "after"
  held.updated_at = "later"
  equal(store.update(root, held), true)
  local on_a, on_b = store.list(root, "docs/a.md"), store.list(root, "docs/b.md")

  equal(#on_a, 0)
  equal(#on_b, 1)
  equal(on_b[1].body, "after")
  equal(on_b[1].updated_at, "later")
end)

test("does not remove a fresh lock taken while a stale one was being cleared", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  add_note(root, "docs/a.md", marked_at, marked_at)
  local lock = store.path(root) .. ".lock"
  vim.fn.writefile({}, lock)
  local stale = os.time() - 60
  vim.uv.fs_utime(lock, stale, stale)

  -- Two instances find the same stale lock. The other one clears it and takes
  -- a fresh lock between our stat and our unlink, which used to remove the
  -- other instance's lock and let both of them write.
  local original_stat = vim.uv.fs_stat
  local theirs
  vim.uv.fs_stat = function(path, ...)
    local info = original_stat(path, ...)
    if path == lock and not theirs then
      vim.uv.fs_unlink(lock)
      local handle = assert(vim.uv.fs_open(lock, "wx", 384))
      vim.uv.fs_close(handle)
      theirs = original_stat(lock).ino
    end
    return info
  end
  local ok, saved = pcall(store.save, root)
  vim.uv.fs_stat = original_stat
  local survivor = vim.uv.fs_stat(lock)
  vim.uv.fs_unlink(lock)
  if not ok then
    error(saved, 0)
  end

  equal(saved, false)
  assert(survivor, "the other instance's lock was removed")
  equal(survivor.ino, theirs)
end)

test("expands only a leading ~ in :ContextMarkMove paths", function()
  local root, store = fixture({ ["docs/a.md"] = document("Alpha") })
  local plugin = require("contextmark")
  add_note(root, "docs/a.md", marked_at, marked_at)
  vim.cmd.edit(root .. "/docs/a.md")

  local original_home = vim.env.HOME
  vim.env.HOME = vim.fs.dirname(root)
  local ok, failure = pcall(function()
    plugin.move("~/" .. vim.fs.basename(root) .. "/docs/a.md", "docs/cost$HOME.md")
    plugin.move("docs/cost$HOME.md", "docs/#tag{x,y}.md")
  end)
  vim.env.HOME = original_home
  local moved = #store.list(root, "docs/#tag{x,y}.md")
  vim.cmd.enew({ bang = true })
  if not ok then
    error(failure, 0)
  end

  equal(moved, 1)
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
