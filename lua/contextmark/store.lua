local config = require("contextmark.config")

local M = {}
-- Cached sidecar contents, plus what is needed to notice that another Neovim
-- instance has written the same file: the stat we read it at, whether we hold
-- unsaved edits, and the ids we deliberately removed this session.
local states = {}
local stamps = {}
local pending = {}
local removed = {}
local unreadable = {}

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

-- Returns the state, or nil plus why it could not be read. "absent" is an empty
-- project; anything else means the file exists but we do not understand it, and
-- those must never be treated the same. Reading a truncated sidecar as an empty
-- project made the next save replace every note in it with nothing.
local function read_state_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil, "absent"
  end
  local raw = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, "unreadable"
  end
  if decoded.version ~= 1 then
    return nil, "written by a newer version of contextmark"
  end

  decoded.comments = type(decoded.comments) == "table" and decoded.comments or {}
  -- Repair rather than drop: the body is what the user wrote, and a note with a
  -- damaged anchor is still worth showing. Dropping it here, or letting it
  -- reach the comparator, loses it or throws on every later read.
  for _, comment in ipairs(decoded.comments) do
    if type(comment) == "table" then
      if type(comment.anchor) ~= "table" then
        comment.anchor = { start_line = 1, end_line = 1, status = "orphaned" }
      end
      comment.anchor.start_line = tonumber(comment.anchor.start_line) or 1
      comment.anchor.end_line = tonumber(comment.anchor.end_line) or comment.anchor.start_line
      comment.created_at = comment.created_at or ""
    end
  end
  return decoded
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

-- Sidecars written before roots were canonicalized are keyed by the path the
-- project was opened through (e.g. a symlink). Find those whose recorded root
-- now resolves to `root` so their notes are not silently hidden.
local function legacy_state_paths(root)
  local directory = storage_dir()
  if not vim.uv.fs_stat(directory) then
    return {}
  end
  local current = state_path(root)
  local result = {}
  for name, kind in vim.fs.dir(directory) do
    local path = directory .. "/" .. name
    if kind == "file" and name:match("%.json$") and path ~= current then
      local state = read_state_file(path)
      local recorded = state and state.root
      local resolved = type(recorded) == "string" and vim.uv.fs_realpath(recorded)
      if resolved and resolved ~= recorded and vim.fs.normalize(resolved) == root then
        result[#result + 1] = { path = path, state = state }
      end
    end
  end
  return result
end

local merge

-- Folds legacy sidecars into the freshly loaded state and persists the result.
-- The old files are renamed only after that save succeeds, so a failed write
-- leaves them in place for the next session to retry.
local function migrate_legacy(root)
  local legacy = legacy_state_paths(root)
  if #legacy == 0 then
    return
  end
  local state = states[root]
  for _, item in ipairs(legacy) do
    state = merge(item.state, state, root)
  end
  states[root] = state
  pending[root] = true
  if M.save(root) then
    -- Keep the old file for recovery, but out of the *.json scan.
    for _, item in ipairs(legacy) do
      os.rename(item.path, item.path .. ".migrated")
    end
  end
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
  local state, reason = read_state_file(path)
  if state then
    state.root = root
    state.comments = drop_removed(root, state.comments)
    unreadable[root] = nil
  else
    state = fresh(root)
    -- Remember that the file on disk holds something we could not parse, so
    -- save() refuses to replace it with this empty state.
    unreadable[root] = reason ~= "absent" and reason or nil
  end
  states[root] = state
  stamps[root] = stamp_of(path)
  -- Only on the first read of a root: later reloads come from another instance
  -- writing the canonical sidecar, which cannot create new legacy files. An
  -- unreadable canonical sidecar is left alone, since save() would refuse it.
  if cached == nil and not unreadable[root] then
    migrate_legacy(root)
  end
  return states[root]
end

-- Marks the cached state as holding edits that are not on disk yet, so the
-- load() inside save() cannot discard them.
local function touch(root)
  local state = load(root)
  pending[root] = true
  return state
end

-- Folds the notes another instance wrote into ours.
function merge(disk, mine, root)
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
  -- Tolerates a damaged entry: :ContextMarkAdopt reads sidecars this instance
  -- did not write, and one malformed note must not make every list throw.
  table.sort(comments, function(left, right)
    local left_file, right_file = left.file or "", right.file or ""
    if left_file ~= right_file then
      return left_file < right_file
    end
    local left_line = (left.anchor or {}).start_line or 0
    local right_line = (right.anchor or {}).start_line or 0
    if left_line ~= right_line then
      return left_line < right_line
    end
    return (left.created_at or "") < (right.created_at or "")
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
  local ok, encoded = pcall(vim.json.encode, state)
  if not ok then
    return false, "could not encode the sidecar: " .. tostring(encoded)
  end
  local temporary = ("%s.tmp-%s"):format(path, tostring(vim.uv.hrtime()))
  local file, error_message = io.open(temporary, "w")
  if not file then
    return false, error_message
  end
  -- A full disk fails here, not at open(). Ignoring these made save() report
  -- success while leaving a truncated file in place of the notes.
  local written, write_error = file:write(encoded)
  local closed, close_error = file:close()
  if not written or not closed then
    os.remove(temporary)
    return false, write_error or close_error or "could not write the sidecar"
  end
  local renamed, rename_error = os.rename(temporary, path)
  if renamed == nil then
    os.remove(temporary)
    return false, rename_error
  end
  return true
end

function M.save(root)
  local state = load(root)
  local path = state_path(root)
  if unreadable[root] then
    -- Whatever is on disk is not ours to replace. Overwriting it would turn a
    -- damaged file into a permanently empty one.
    return false,
      ("refusing to overwrite an unreadable sidecar at %s (%s)"):format(path, unreadable[root])
  end
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
        local resolved = vim.uv.fs_realpath(recorded) or recorded
        local missing = vim.uv.fs_stat(recorded) == nil
        -- The project that owned these notes is gone, or its root sits on the
        -- same branch of the tree as this one -- which is what a change in root
        -- derivation looks like.
        local related = resolved ~= root
          and (
            resolved:sub(1, #root + 1) == root .. "/"
            or root:sub(1, #resolved + 1) == resolved .. "/"
          )
        -- Or the files themselves are here. A root derived a different way is
        -- often a sibling of the old one rather than an ancestor, so path shape
        -- alone misses exactly the case the upgrade notes send people here for.
        local overlaps = false
        if not missing and not related then
          for _, comment in ipairs(state.comments) do
            local candidate = (root == "/" and "" or root) .. "/" .. tostring(comment.file)
            if vim.uv.fs_stat(candidate) then
              overlaps = true
              break
            end
          end
        end
        if missing or related or overlaps then
          result[#result + 1] = {
            path = path,
            root = recorded,
            missing = missing,
            overlaps = overlaps,
            related = related,
            -- The notes name files that exist here already, so their paths are
            -- relative to this root as they stand.
            keep_paths = missing or overlaps,
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
  for _, comment in ipairs(drop_removed(root, comments or {})) do
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
  unreadable = {}
end

return M
