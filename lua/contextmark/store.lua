local config = require("contextmark.config")

local M = {}
local states = {}

local function storage_dir()
  local configured = config.get().storage.dir
  return configured and vim.fs.normalize(configured) or (vim.fn.stdpath("state") .. "/contextmark")
end

local function state_path(root)
  local name = vim.fn.fnamemodify(root, ":t")
  local hash = vim.fn.sha256(root):sub(1, 16)
  return ("%s/%s-%s.json"):format(storage_dir(), name, hash)
end

local function fresh(root)
  return { version = 1, root = root, comments = {} }
end

local function read_state(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local raw = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" and decoded.version == 1 then
    decoded.comments = decoded.comments or {}
    return decoded
  end
  return nil
end

-- Sidecars written before roots were canonicalized are keyed by the path the
-- project was opened through (e.g. a symlink). Find those whose recorded root
-- now resolves to `root` so their notes are not silently hidden.
local function legacy_state_paths(root)
  local current = state_path(root)
  local result = {}
  for name, kind in vim.fs.dir(storage_dir()) do
    local path = storage_dir() .. "/" .. name
    if kind == "file" and name:match("%.json$") and path ~= current then
      local state = read_state(path)
      local resolved = state and type(state.root) == "string" and vim.uv.fs_realpath(state.root)
      if resolved and resolved ~= state.root and vim.fs.normalize(resolved) == root then
        result[#result + 1] = { path = path, state = state }
      end
    end
  end
  return result
end

local function load(root)
  if states[root] then
    return states[root]
  end

  local state = read_state(state_path(root)) or fresh(root)
  state.root = root
  states[root] = state

  local legacy = legacy_state_paths(root)
  if #legacy > 0 then
    local known = {}
    for _, comment in ipairs(state.comments) do
      known[comment.id] = true
    end
    for _, item in ipairs(legacy) do
      for _, comment in ipairs(item.state.comments) do
        if not known[comment.id] then
          known[comment.id] = true
          state.comments[#state.comments + 1] = comment
        end
      end
    end
    if M.save(root) then
      -- Keep the old file for recovery, but out of the *.json scan.
      for _, item in ipairs(legacy) do
        os.rename(item.path, item.path .. ".migrated")
      end
    end
  end
  return state
end

local function sort(comments)
  table.sort(comments, function(left, right)
    if left.file ~= right.file then
      return left.file < right.file
    end
    if left.anchor.start_line ~= right.anchor.start_line then
      return left.anchor.start_line < right.anchor.start_line
    end
    return left.created_at < right.created_at
  end)
  return comments
end

function M.path(root)
  return state_path(root)
end

function M.save(root)
  local state = load(root)
  vim.fn.mkdir(storage_dir(), "p")
  local encoded = vim.json.encode(state)
  local path = state_path(root)
  local temporary = ("%s.tmp-%s"):format(path, tostring(vim.uv.hrtime()))
  local file, error_message = io.open(temporary, "w")
  if not file then
    return false, error_message
  end
  file:write(encoded)
  file:close()
  local ok, rename_error = os.rename(temporary, path)
  return ok ~= nil, rename_error
end

function M.list(root, relative_file)
  local result = {}
  for _, comment in ipairs(load(root).comments) do
    if not relative_file or comment.file == relative_file then
      result[#result + 1] = comment
    end
  end
  return sort(result)
end

function M.add(root, comment)
  load(root).comments[#load(root).comments + 1] = comment
  return M.save(root)
end

function M.update(root, comment)
  local state = load(root)
  for index, current in ipairs(state.comments) do
    if current.id == comment.id then
      state.comments[index] = comment
      return M.save(root)
    end
  end
  return false, "comment not found"
end

function M.remove(root, id)
  local state = load(root)
  for index, comment in ipairs(state.comments) do
    if comment.id == id then
      table.remove(state.comments, index)
      return M.save(root)
    end
  end
  return false, "comment not found"
end

function M.reset_cache()
  states = {}
end

return M
