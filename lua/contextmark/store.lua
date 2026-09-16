local config = require("contextmark.config")

local M = {}
-- Cached sidecar contents, plus what is needed to notice that another Neovim
-- instance has written the same file: the stat we read it at, whether we hold
-- unsaved edits, and the ids we deliberately removed this session.
local states = {}
local stamps = {}
local pending = {}
local removed = {}

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

local function read_state_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local raw = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "table" and decoded.version == 1 then
    decoded.comments = type(decoded.comments) == "table" and decoded.comments or {}
    return decoded
  end
  return nil
end

local function stamp_of(path)
  local info = vim.uv.fs_stat(path)
  if not info then
    return nil
  end
  return { size = info.size, sec = info.mtime.sec, nsec = info.mtime.nsec }
end

local function same_stamp(left, right)
  if left == nil or right == nil then
    return left == right
  end
  return left.size == right.size and left.sec == right.sec and left.nsec == right.nsec
end

-- Deletions made this session outlive a reload or a merge; otherwise a
-- concurrent writer's copy of the sidecar brings every removed note back.
local function drop_removed(root, comments)
  local tombstones = removed[root]
  if not tombstones then
    return comments
  end
  local kept = {}
  for _, comment in ipairs(comments) do
    if not tombstones[comment.id] then
      kept[#kept + 1] = comment
    end
  end
  return kept
end

local function load(root)
  local cached = states[root]
  if cached then
    -- Unsaved local edits win; otherwise pick up a sidecar that another Neovim
    -- instance has written since we read it. Without this the cache was held
    -- for the whole session and the next save replaced their notes with our
    -- stale copy.
    if pending[root] or same_stamp(stamps[root], stamp_of(state_path(root))) then
      return cached
    end
  end

  local path = state_path(root)
  local state = read_state_file(path)
  if state then
    state.root = root
    state.comments = drop_removed(root, state.comments)
  else
    state = fresh(root)
  end
  states[root] = state
  stamps[root] = stamp_of(path)
  return state
end

-- Marks the cached state as holding edits that are not on disk yet, so the
-- load() inside save() cannot discard them.
local function touch(root)
  local state = load(root)
  pending[root] = true
  return state
end

-- Folds the notes another instance wrote into ours.
local function merge(disk, mine, root)
  local known = {}
  for _, comment in ipairs(mine.comments) do
    known[comment.id] = true
  end
  for _, comment in ipairs(drop_removed(root, disk.comments)) do
    if not known[comment.id] then
      mine.comments[#mine.comments + 1] = comment
    end
  end
  if type(disk.files) == "table" then
    mine.files = mine.files or {}
    for relative, fingerprint in pairs(disk.files) do
      if mine.files[relative] == nil then
        mine.files[relative] = fingerprint
      end
    end
  end
  return mine
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

-- Per-file identity fingerprints, keyed by the same relative path as the notes.
-- Added alongside version 1 on purpose: load() round-trips unknown keys, so an
-- older sidecar simply has no fingerprints and is treated as "unknown".
function M.fingerprint(root, relative)
  local files = load(root).files
  return files and files[relative] or nil
end

-- Mutates the in-memory state only. The caller decides when to persist, so a
-- fingerprint refresh rides along with a write that was going to happen anyway
-- instead of touching the disk on every BufEnter.
function M.set_fingerprint(root, relative, fingerprint)
  local state = touch(root)
  state.files = state.files or {}
  state.files[relative] = fingerprint
end

local function has_comments_for(state, relative)
  for _, comment in ipairs(state.comments) do
    if comment.file == relative then
      return true
    end
  end
  return false
end

local lock_attempts = 40
local lock_wait_ms = 10
local lock_stale_seconds = 5

-- The whole read-modify-write has to be exclusive. The atomic rename only
-- guarantees that no reader sees a half-written file; it does not stop two
-- instances from each reading, merging and writing, with the later rename
-- discarding the earlier one's notes.
local function acquire_lock(path)
  local lock = path .. ".lock"
  for _ = 1, lock_attempts do
    local handle = vim.uv.fs_open(lock, "wx", 384)
    if handle then
      vim.uv.fs_close(handle)
      return lock
    end
    local info = vim.uv.fs_stat(lock)
    if info and os.time() - info.mtime.sec > lock_stale_seconds then
      -- Left behind by an instance that died before releasing it.
      vim.uv.fs_unlink(lock)
    else
      vim.uv.sleep(lock_wait_ms)
    end
  end
  return nil
end

local function write_state(state, path)
  local encoded = vim.json.encode(state)
  local temporary = ("%s.tmp-%s"):format(path, tostring(vim.uv.hrtime()))
  local file, error_message = io.open(temporary, "w")
  if not file then
    return false, error_message
  end
  file:write(encoded)
  file:close()
  local ok, rename_error = os.rename(temporary, path)
  if ok == nil then
    os.remove(temporary)
    return false, rename_error
  end
  return true
end

function M.save(root)
  local state = load(root)
  local path = state_path(root)
  vim.fn.mkdir(storage_dir(), "p")

  local lock = acquire_lock(path)
  if not lock then
    -- Refuse rather than overwrite: another instance is mid-write, and our copy
    -- does not include whatever it is about to store.
    return false, "sidecar is locked by another Neovim instance"
  end

  -- Fold in anything written since we read the file. A second Neovim instance
  -- editing the same project would otherwise lose every note it added.
  if not same_stamp(stamps[root], stamp_of(path)) then
    local disk = read_state_file(path)
    if disk then
      state = merge(disk, state, root)
      states[root] = state
    end
  end

  local ok, error_message = write_state(state, path)
  vim.uv.fs_unlink(lock)
  if not ok then
    return false, error_message
  end
  stamps[root] = stamp_of(path)
  pending[root] = nil
  return true
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
  local state = touch(root)
  state.comments[#state.comments + 1] = comment
  return M.save(root)
end

function M.update(root, comment)
  -- pending is set only once the edit has actually landed. Setting it up front
  -- meant a miss ("comment not found", e.g. another instance deleted the note)
  -- left the cache marked dirty forever, so this instance stopped reloading the
  -- sidecar and its next save rolled back everything the other one had done.
  local state = load(root)
  for index, current in ipairs(state.comments) do
    if current.id == comment.id then
      state.comments[index] = comment
      pending[root] = true
      return M.save(root)
    end
  end
  return false, "comment not found"
end

-- Re-points every note on `from` at `to`, carrying the file's identity with it.
-- One pass and one write, so a rename does not turn into a save per note.
function M.rekey(root, from, to)
  -- Moving a file onto itself would drop its identity and silently disarm the
  -- replacement guard, so treat it as a no-op.
  if from == to then
    return true, 0
  end

  local state = touch(root)
  local moved = 0
  for _, comment in ipairs(state.comments) do
    if comment.file == from then
      comment.file = to
      moved = moved + 1
    end
  end
  if state.files and state.files[from] ~= nil then
    -- Never overwrite the destination's own identity: the notes already there
    -- were written against that file, and replacing their baseline would flag
    -- every one of them as belonging to a different file.
    if state.files[to] == nil then
      state.files[to] = state.files[from]
    end
    state.files[from] = nil
  end
  local ok, error_message = M.save(root)
  return ok, moved, error_message
end

function M.remove(root, id)
  local state = load(root)
  for index, comment in ipairs(state.comments) do
    if comment.id == id then
      local relative = comment.file
      table.remove(state.comments, index)
      pending[root] = true
      -- Remember the deletion so a merge with a concurrent writer cannot bring
      -- it back.
      removed[root] = removed[root] or {}
      removed[root][id] = true
      -- Drop the fingerprint once the file has no notes left, so the sidecar
      -- does not accumulate identities for files nobody tracks any more.
      if state.files and state.files[relative] and not has_comments_for(state, relative) then
        state.files[relative] = nil
      end
      return M.save(root)
    end
  end
  return false, "comment not found"
end

-- Sidecars that hold notes but are not the one this root reads.
--
-- The file name is a hash of the project root, so anything that changes the root
-- string -- moving or renaming the project, or a change to how the root is
-- derived -- leaves the notes on disk but out of reach. Every sidecar records
-- the root it was written for, which is what makes them findable again.
function M.adoptable(root)
  local directory = storage_dir()
  if not vim.uv.fs_stat(directory) then
    return {}
  end

  local mine = state_path(root)
  local result = {}
  for name, kind in vim.fs.dir(directory) do
    local path = directory .. "/" .. name
    if kind == "file" and name:match("%.json$") and path ~= mine then
      local state = read_state_file(path)
      local recorded = state and state.root
      if state and #state.comments > 0 and type(recorded) == "string" and recorded ~= root then
        -- Either the project that owned these notes is gone, or its root sits on
        -- the same branch of the tree as this one (which is what a change in
        -- root derivation looks like). A live, unrelated project keeps its own.
        local missing = vim.uv.fs_stat(recorded) == nil
        local related = recorded:sub(1, #root + 1) == root .. "/"
          or root:sub(1, #recorded + 1) == recorded .. "/"
        if missing or related then
          result[#result + 1] = {
            path = path,
            root = recorded,
            missing = missing,
            count = #state.comments,
            state = state,
          }
        end
      end
    end
  end
  table.sort(result, function(left, right)
    return left.root < right.root
  end)
  return result
end

-- Adds notes that this root does not already have. The caller is responsible for
-- rebasing `file` onto this root first; store does not do path arithmetic.
function M.import(root, comments, files)
  local state = touch(root)
  local known = {}
  for _, comment in ipairs(state.comments) do
    known[comment.id] = true
  end

  local added = 0
  for _, comment in ipairs(comments or {}) do
    if not known[comment.id] then
      state.comments[#state.comments + 1] = comment
      known[comment.id] = true
      added = added + 1
    end
  end
  for relative, fingerprint in pairs(files or {}) do
    state.files = state.files or {}
    if state.files[relative] == nil then
      state.files[relative] = fingerprint
    end
  end

  local ok, error_message = M.save(root)
  return ok, added, error_message
end

function M.reset_cache()
  states = {}
  stamps = {}
  pending = {}
  removed = {}
end

return M
