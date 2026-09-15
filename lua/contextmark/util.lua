-- Shared utilities for contextmark.nvim.
local M = {}

local function normalize(path)
  local expanded = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  -- Resolve symlinks so that the same file reached through different paths
  -- (/tmp/x vs /private/tmp/x on macOS) maps to one project root and sidecar.
  -- fs_realpath returns nil for paths that do not exist yet; keep the literal
  -- path in that case.
  local resolved = vim.uv.fs_realpath(expanded) or expanded
  return (vim.fs.normalize(resolved):gsub("/$", ""))
end

function M.project_root(path)
  path = path and path ~= "" and normalize(path) or normalize(vim.fn.getcwd())
  local root = vim.fs.root(path, { ".git" })
  return root and normalize(root) or normalize(vim.fn.getcwd())
end

function M.relative_path(path, root)
  path, root = normalize(path), normalize(root)
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":t")
end

function M.absolute_path(root, relative)
  return normalize(root .. "/" .. relative)
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

function M.read_buffer_or_file(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
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
