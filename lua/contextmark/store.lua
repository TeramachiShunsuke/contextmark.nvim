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

local function load(root)
  if states[root] then
    return states[root]
  end

  local state = fresh(root)
  local file = io.open(state_path(root), "r")
  if file then
    local raw = file:read("*a")
    file:close()
    local ok, decoded = pcall(vim.json.decode, raw)
    if ok and type(decoded) == "table" and decoded.version == 1 then
      state = decoded
      state.root = root
      state.comments = state.comments or {}
    end
  end
  states[root] = state
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
