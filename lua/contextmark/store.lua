local config = require("contextmark.config")

local M = {}
-- Cached sidecar contents, plus what is needed to notice that another Neovim
-- instance has written the same file: the stat we read it at, the contents we
-- last read or wrote (the base a concurrent change is compared against), and the
-- ids we deliberately removed this session.
local states = {}
local stamps = {}
local bases = {}
local removed = {}
local unreadable = {}
-- Legacy sidecars already folded into a root, waiting for a successful save.
local retiring = {}

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
  local file, open_error = io.open(path, "r")
  if not file then
    -- Only a missing file is an empty project. One that exists but cannot be
    -- opened (permissions, I/O error) still holds notes we must not replace.
    if vim.uv.fs_stat(path) then
      return nil, ("unreadable: %s"):format(open_error or "cannot open")
    end
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
  -- Every sidecar this version writes has a comments list, even when empty.
  -- Without one the file is damaged, not an empty project.
  if type(decoded.comments) ~= "table" then
    return nil, "unreadable: no comments list"
  end

  local comments = {}
  for _, comment in ipairs(decoded.comments) do
    -- A non-table entry carries no note to keep, and would throw in every
    -- comparator and merge that indexes it.
    if type(comment) == "table" then
      comments[#comments + 1] = comment
    end
  end
  decoded.comments = comments
  -- Repair rather than drop: the body is what the user wrote, and a note with a
  -- damaged anchor is still worth showing. Dropping it here, or letting it
  -- reach the comparator, loses it or throws on every later read.
  for _, comment in ipairs(decoded.comments) do
    if type(comment.anchor) ~= "table" then
      comment.anchor = { start_line = 1, end_line = 1, status = "orphaned" }
    end
    comment.anchor.start_line = tonumber(comment.anchor.start_line) or 1
    comment.anchor.end_line = tonumber(comment.anchor.end_line) or comment.anchor.start_line
    comment.created_at = comment.created_at or ""
  end
  return decoded
end

local function stamp_of(path)
  local info = vim.uv.fs_stat(path)
  if not info then
    return nil
  end
  -- Every writer renames a fresh temp file into place, so the inode changes on
  -- each write. Size and mtime alone miss a same-size rewrite on filesystems
  -- whose mtime only has one-second resolution.
  return { ino = info.ino, size = info.size, sec = info.mtime.sec, nsec = info.mtime.nsec }
end

local function same_stamp(left, right)
  if left == nil or right == nil then
    return left == right
  end
  return left.ino == right.ino
    and left.size == right.size
    and left.sec == right.sec
    and left.nsec == right.nsec
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

local function by_id(comments)
  local result = {}
  for _, comment in ipairs(comments or {}) do
    if comment.id ~= nil then
      result[comment.id] = comment
    end
  end
  return result
end

-- Folds what another instance wrote (`disk`) into ours (`mine`), using the last
-- sidecar we read or wrote (`base`) to tell whose change each difference is.
--
-- A plain "ours wins by id" union cannot do this: it reverts the other
-- instance's edits to notes we never touched and resurrects the notes it
-- deleted. Comparing both sides against the base keeps each side's own changes.
local function reconcile(base, mine, disk, root)
  base = base or { comments = {} }
  local base_ids, disk_ids = by_id(base.comments), by_id(disk.comments)
  local tombstones = removed[root] or {}
  local comments, seen = {}, {}
  for _, comment in ipairs(mine.comments) do
    local id = comment.id
    if id == nil then
      comments[#comments + 1] = comment
    else
      seen[id] = true
      local original = base_ids[id]
      if original == nil or not vim.deep_equal(original, comment) then
        -- Added or edited here.
        comments[#comments + 1] = comment
      elseif disk_ids[id] then
        -- Untouched here, so theirs is at least as new.
        comments[#comments + 1] = disk_ids[id]
      end
      -- Untouched here and gone from disk: deleted there.
    end
  end
  for _, comment in ipairs(disk.comments) do
    local id = comment.id
    -- Present in the base but not here means we deleted it.
    if id ~= nil and not seen[id] and base_ids[id] == nil and not tombstones[id] then
      comments[#comments + 1] = comment
    end
  end

  local files = {}
  local keys = {}
  for _, side in ipairs({ base.files, mine.files, disk.files }) do
    for relative in pairs(type(side) == "table" and side or {}) do
      keys[relative] = true
    end
  end
  for relative in pairs(keys) do
    local original = type(base.files) == "table" and base.files[relative] or nil
    local ours = type(mine.files) == "table" and mine.files[relative] or nil
    local theirs = type(disk.files) == "table" and disk.files[relative] or nil
    if vim.deep_equal(original, ours) then
      files[relative] = theirs
    else
      files[relative] = ours
    end
  end

  mine.comments = comments
  mine.files = next(files) and files or nil
  return mine
end

-- Adds the notes and fingerprints of `other` that `state` does not have yet.
local function absorb(state, other, root)
  local known = by_id(state.comments)
  for _, comment in ipairs(drop_removed(root, other.comments)) do
    if comment.id ~= nil and not known[comment.id] then
      known[comment.id] = comment
      state.comments[#state.comments + 1] = comment
    end
  end
  if type(other.files) == "table" then
    state.files = state.files or {}
    for relative, fingerprint in pairs(other.files) do
      if state.files[relative] == nil then
        state.files[relative] = fingerprint
      end
    end
  end
  return state
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
      if
        resolved
        and resolved ~= recorded
        and vim.fs.normalize(resolved, { expand_env = false }) == root
      then
        result[#result + 1] = { path = path, state = state }
      end
    end
  end
  return result
end

-- Folds legacy sidecars into the freshly loaded state. The old files are renamed
-- by the first save that succeeds afterwards, not only by the save attempted
-- here: if that one fails, a later successful save still retires them, so a note
-- deleted in the meantime is not merged back in by the next session.
local function migrate_legacy(root)
  local legacy = legacy_state_paths(root)
  if #legacy == 0 then
    return
  end
  local state = states[root]
  for _, item in ipairs(legacy) do
    absorb(state, item.state, root)
  end
  retiring[root] = vim.tbl_map(function(item)
    return item.path
  end, legacy)
  M.save(root)
end

local function load(root)
  local cached = states[root]
  local path = state_path(root)
  -- Stat before reading: a write landing in between is then seen as a change
  -- on the next load, instead of being recorded as already read.
  local stamp = stamp_of(path)
  if cached and same_stamp(stamps[root], stamp) then
    return cached
  end

  local disk, reason = read_state_file(path)
  if disk then
    disk.root = root
    disk.comments = drop_removed(root, disk.comments)
    unreadable[root] = nil
    -- Another instance wrote the sidecar since we read it. Fold its changes into
    -- ours rather than replacing the cache, which would drop edits that are only
    -- in memory (including ones whose save failed).
    states[root] = cached and reconcile(bases[root], cached, disk, root) or disk
    bases[root] = vim.deepcopy(disk)
  else
    -- Remember that the file on disk holds something we could not parse, so
    -- save() refuses to replace it.
    unreadable[root] = reason ~= "absent" and reason or nil
    if not cached then
      states[root] = fresh(root)
    end
    if reason == "absent" then
      -- Nothing on disk to compare against: everything in memory is ours.
      bases[root] = nil
    end
  end
  stamps[root] = stamp
  -- Only on the first read of a root: later reloads come from another instance
  -- writing the canonical sidecar, which cannot create new legacy files. An
  -- unreadable canonical sidecar is left alone, since save() would refuse it.
  if cached == nil and not unreadable[root] then
    migrate_legacy(root)
  end
  return states[root]
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
  local state = load(root)
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
  local function refuse()
    -- Whatever is on disk is not ours to replace. Overwriting it would turn a
    -- damaged file into a permanently empty one.
    return false,
      ("refusing to overwrite an unreadable sidecar at %s (%s)"):format(path, unreadable[root])
  end
  if unreadable[root] then
    return refuse()
  end
  vim.fn.mkdir(storage_dir(), "p")

  local lock = acquire_lock(path)
  if not lock then
    -- Refuse rather than overwrite: another instance is mid-write, and our copy
    -- does not include whatever it is about to store.
    return false, "sidecar is locked by another Neovim instance"
  end

  -- Fold in anything written between load() and taking the lock. A second
  -- Neovim instance editing the same project would otherwise lose its changes.
  local stamp = stamp_of(path)
  if not same_stamp(stamps[root], stamp) then
    local disk, reason = read_state_file(path)
    if disk then
      disk.root = root
      disk.comments = drop_removed(root, disk.comments)
      state = reconcile(bases[root], state, disk, root)
      states[root] = state
    elseif reason ~= "absent" then
      unreadable[root] = reason
      stamps[root] = stamp
      vim.uv.fs_unlink(lock)
      return refuse()
    end
  end

  local ok, error_message = write_state(state, path)
  if not ok then
    vim.uv.fs_unlink(lock)
    return false, error_message
  end
  -- Stat before releasing the lock, so a writer waiting on it cannot slip a
  -- change in that we would then record as already read.
  stamps[root] = stamp_of(path)
  bases[root] = vim.deepcopy(state)
  vim.uv.fs_unlink(lock)

  if retiring[root] then
    -- Keep the old files for recovery, but out of the *.json scan.
    for _, legacy in ipairs(retiring[root]) do
      os.rename(legacy, legacy .. ".migrated")
    end
    retiring[root] = nil
  end
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
  local state = load(root)
  state.comments[#state.comments + 1] = comment
  return M.save(root)
end

-- Applies an edit of the note's text. Only the body and its timestamp are taken
-- from `comment`: the caller held it while waiting for input, and a move,
-- re-anchor or reload in the meantime would otherwise be reverted by its stale
-- `file` and `anchor`.
function M.update(root, comment)
  local state = load(root)
  for _, current in ipairs(state.comments) do
    if current.id == comment.id then
      current.body = comment.body
      current.updated_at = comment.updated_at
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

  local state = load(root)
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
--
-- Every such sidecar is returned. Deciding which of their notes belong to `root`
-- needs path arithmetic, which is the caller's job.
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
        result[#result + 1] = {
          path = path,
          root = recorded,
          missing = vim.uv.fs_stat(recorded) == nil,
          state = state,
        }
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
  local state = load(root)
  local known = by_id(state.comments)

  local added = 0
  for _, comment in ipairs(drop_removed(root, comments or {})) do
    -- A note without an id cannot be edited, deleted or deduplicated. Skip it
    -- rather than abort the whole adoption; the source sidecar keeps it.
    if comment.id ~= nil and not known[comment.id] then
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
  bases = {}
  retiring = {}
  removed = {}
  unreadable = {}
end

return M
