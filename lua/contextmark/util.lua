-- Shared utilities for contextmark.nvim.
local M = {}

-- Anchor statuses that mean "do not trust the stored position as-is".
local warning_status = {
  stale = true,
  mismatch = true,
  orphaned = true,
}

-- Buffer name schemes that look like files but are not. A note keyed on one of
-- these would be stored against the wrong path (fugitive:// collapses to the
-- blob's basename, oil:// to a directory name).
local function has_scheme(path)
  return path:match("^%a[%w+.-]*://") ~= nil
end

-- Keep "/" intact while dropping a trailing slash from every other path.
local function without_trailing_slash(path)
  local trimmed = path:gsub("(.)/$", "%1")
  return trimmed
end

-- File names may contain "$", and vim.fs.normalize() expands environment
-- variables by default: "cost$HOME.md" became a key no file or buffer matches.
local function fs_normalize(path)
  return vim.fs.normalize(path, { expand_env = false })
end

-- vim.fs.normalize() collapses interior duplicate slashes but keeps a leading
-- "//", so joining onto the filesystem root needs its own case.
local function join(parent, leaf)
  if parent == "/" then
    return "/" .. leaf
  end
  return parent .. "/" .. leaf
end

-- Absolute and slash-normalized, but NOT symlink-resolved.
local function literal_path(path)
  return without_trailing_slash(fs_normalize(vim.fn.fnamemodify(path, ":p")))
end

local function normalize(path)
  local trimmed = literal_path(path)
  -- Resolve symlinks so one inode always yields one key. Neovim resolves the
  -- directory part of a buffer name but leaves a symlinked file itself alone,
  -- so this is what collapses "docs/alias.md" onto "docs/real.md".
  local real = vim.uv.fs_realpath(trimmed)
  if real then
    return without_trailing_slash(fs_normalize(real))
  end

  -- fs_realpath() fails on a path that does not exist: the normal case for a
  -- note whose file was renamed away, and for a new file under a directory that
  -- has not been created yet. Resolve the deepest ancestor that does exist and
  -- re-join the missing tail, otherwise a resolved root ("/private/var/...")
  -- and an unresolved file ("/var/...") stop sharing a prefix and
  -- relative_path() reports the file as outside its own root.
  local tail = {}
  local current = trimmed
  while true do
    local parent = vim.fs.dirname(current)
    if not parent or parent == "" or parent == current then
      return trimmed
    end
    table.insert(tail, 1, vim.fs.basename(current))
    local real_parent = vim.uv.fs_realpath(parent)
    if real_parent then
      local resolved = without_trailing_slash(fs_normalize(real_parent))
      for _, segment in ipairs(tail) do
        resolved = join(resolved, segment)
      end
      return resolved
    end
    current = parent
  end
end

local function under(path, root)
  if root == "/" then
    return path ~= "/" and path:sub(2) or nil
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return nil
end

function M.is_warning_status(status)
  return warning_status[status] == true
end

-- Human-readable marker for an unresolved anchor, or nil when the note is
-- healthy. The status used to exist only as a highlight group, so a note that
-- had lost its anchor looked identical to a good one in every text surface.
local status_labels = {
  stale = "unresolved",
  mismatch = "different file?",
  orphaned = "file is empty",
}

function M.status_label(status)
  return status_labels[status]
end

-- The same warning phrased for the prompt the agent receives. Without this the
-- agent is handed an excerpt it believes the user selected, with no hint that
-- the note could not be placed.
local status_notes = {
  stale = "unresolved - the noted text was edited; the excerpt below is the original text",
  mismatch = "different file? - the file now at this path does not match the note;"
    .. " the excerpt below is the original text",
  orphaned = "file is empty - the excerpt below is the original text",
}

function M.status_note(status)
  local note = status_notes[status]
  return note and ("Status: " .. note) or nil
end

-- True when the path can own notes at all. Scheme-prefixed buffer names are
-- rejected because relative_path() cannot map them back to a real file.
function M.is_notable_path(path)
  return type(path) == "string" and path ~= "" and not has_scheme(path)
end

function M.normalize(path)
  return normalize(path)
end

function M.project_root(path)
  if not M.is_notable_path(path) then
    return nil
  end
  -- Look for the marker along the path as written. Resolving symlinks first
  -- would hand a repository-internal link that points outside the repository
  -- over to the target's own root, silently moving the note into a different
  -- project's sidecar.
  local literal = literal_path(path)
  local root = vim.fs.root(literal, { ".git" })
  if root then
    return normalize(root)
  end
  -- No repository marker. Key on the file's own directory rather than the
  -- current working directory: the parent never changes under :cd, so the
  -- note keeps pointing at the same sidecar.
  local parent = vim.fs.dirname(literal)
  return parent and parent ~= "" and normalize(parent) or nil
end

-- Returns nil when the path is not inside root. Callers must treat nil as
-- "this buffer cannot own notes" instead of falling back to a basename, which
-- would make unrelated files with the same name share a key.
function M.relative_path(path, root)
  if not M.is_notable_path(path) or not M.is_notable_path(root) then
    return nil
  end
  local normalized_root = normalize(root)
  -- Prefer the resolved form so symlink aliases of one file collapse onto a
  -- single key, but fall back to the path as written when resolving escapes the
  -- root: a link out of the repository must stay keyed inside the repository.
  for _, candidate in ipairs({ normalize(path), literal_path(path) }) do
    if candidate ~= normalized_root then
      local relative = under(candidate, normalized_root)
      if relative then
        return relative
      end
    end
  end
  return nil
end

function M.absolute_path(root, relative)
  return normalize(join(without_trailing_slash(fs_normalize(root)), relative))
end

-- The single gate every note-owning code path goes through. Returns nil when the
-- buffer must not own notes: a scratch/terminal/help buffer, a scheme-prefixed
-- name (fugitive://, oil://), or a file that does not sit inside its own root.
-- Returning nil here is what keeps unrelated files from sharing a storage key.
function M.buffer_context(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not M.is_notable_path(path) then
    return nil
  end
  local root = M.project_root(path)
  if not root then
    return nil
  end
  local relative = M.relative_path(path, root)
  if not relative then
    return nil
  end
  return normalize(path), root, relative
end

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.id(root, file, body)
  -- Vim strings containing NUL are converted to Blob values by vim.fn.sha256(),
  -- which raises E976. JSON keeps the fields unambiguous without introducing NUL.
  local seed = vim.json.encode({ root, file, body, tostring(vim.uv.hrtime()) })
  return "cm-" .. vim.fn.sha256(seed):sub(1, 16)
end

-- Exact buffer lookup. vim.fn.bufnr() matches file patterns, so bufnr("a.md")
-- can return the buffer for "a.md.bak" and hand back the wrong file's text.
local function buffer_for(path)
  local target = normalize(path)
  local leaf = vim.fs.basename(target)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and not has_scheme(name) then
        -- Compare the raw name and the basename before normalizing: resolving
        -- every loaded buffer turned this into O(notes x buffers) realpath
        -- calls, which stalls :ContextMarkSend in a long-lived session.
        if name == target then
          return bufnr
        end
        if vim.fs.basename(name) == leaf and normalize(name) == target then
          return bufnr
        end
      end
    end
  end
  return nil
end

function M.read_buffer_or_file(path)
  local bufnr = buffer_for(path)
  if bufnr then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

local glob_patterns = {}

-- "*" matches every filetype, "markdown*" matches markdown and markdown.mdx.
local function glob_to_pattern(glob)
  local pattern = glob_patterns[glob]
  if not pattern then
    pattern = "^" .. glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
    glob_patterns[glob] = pattern
  end
  return pattern
end

function M.is_filetype_allowed(filetype, allowed)
  if type(allowed) == "function" then
    return allowed(filetype) and true or false
  end
  if type(allowed) == "string" then
    allowed = { allowed }
  end
  for _, entry in ipairs(allowed or {}) do
    if entry == filetype then
      return true
    end
    if type(entry) == "string" and entry:find("*", 1, true) then
      if filetype:match(glob_to_pattern(entry)) then
        return true
      end
    end
  end
  return false
end

function M.range_label(start_line, end_line)
  if start_line == end_line then
    return ("Line %d"):format(start_line)
  end
  return ("Lines %d-%d"):format(start_line, end_line)
end

return M
