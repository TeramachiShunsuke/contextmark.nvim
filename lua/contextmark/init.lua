local anchor = require("contextmark.anchor")
local config = require("contextmark.config")
local delivery = require("contextmark.delivery")
local identity = require("contextmark.identity")
local prompt = require("contextmark.prompt")
local render = require("contextmark.render")
local selection = require("contextmark.selection")
local store = require("contextmark.store")
local ui = require("contextmark.ui")
local util = require("contextmark.util")

local M = {}
local configured = false
local map_buffer

local canonicalize_keys

local function initialize_buffer(bufnr)
  if util.is_filetype_allowed(vim.bo[bufnr].filetype, config.get().filetypes) then
    map_buffer(bufnr)
    canonicalize_keys(bufnr)
    render.render(bufnr)
  end
end

local function current_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local path, root, relative = util.buffer_context(bufnr)
  if not path then
    return nil
  end
  return bufnr, path, root, relative
end

local function notify_save(ok, error_message)
  if not ok then
    vim.notify(
      "contextmark: could not save sidecar: " .. tostring(error_message),
      vim.log.levels.ERROR
    )
  end
end

function M.add()
  local bufnr, _, root, relative = current_context()
  if not bufnr then
    -- Rejected by util.buffer_context(): no file name, a special buftype, or a
    -- scheme-prefixed name such as fugitive:// or oil://. Storing a note from
    -- one of those would key it on the wrong path.
    vim.notify(
      "contextmark: this buffer cannot hold notes"
        .. " (no file name, special buftype, scheme-prefixed name,"
        .. " or a path that does not resolve inside its own project root)",
      vim.log.levels.WARN
    )
    return
  end
  local selected = selection.current()
  local start_line, end_line = selected.start_line, selected.end_line
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local captured =
    anchor.capture(lines, start_line, end_line, config.get().storage.context_lines, selected)

  if identity.compare(store.fingerprint(root, relative), lines) == "replaced" then
    -- Otherwise the new note is born carrying a "different file?" marker with
    -- no explanation: the flag belongs to the file, not to this note.
    vim.notify(
      ("contextmark: %s does not match what its existing notes were written against,"):format(
        relative
      ) .. " so this note will be flagged too (:ContextMarkReanchor accepts this file)",
      vim.log.levels.WARN
    )
  end

  ui.edit("", ("Note for %s:%d-%d"):format(relative, start_line, end_line), function(body)
    local now = util.now()
    local comment = {
      id = util.id(root, relative, body),
      file = relative,
      filetype = vim.bo[bufnr].filetype,
      body = body,
      created_at = now,
      updated_at = now,
      anchor = captured,
    }
    local ok, error_message = store.add(root, comment)
    notify_save(ok, error_message)
    render.render(bufnr)
  end)
end

function M.edit()
  local comment, root = render.at_cursor()
  if not comment then
    vim.notify("contextmark: no comment at cursor", vim.log.levels.WARN)
    return
  end
  ui.edit(comment.body, "Edit note", function(body)
    comment.body = body
    comment.updated_at = util.now()
    local ok, error_message = store.update(root, comment)
    notify_save(ok, error_message)
    render.render()
  end)
end

function M.delete()
  local comment, root = render.at_cursor()
  if not comment then
    vim.notify("contextmark: no comment at cursor", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "Cancel", "Delete" }, {
    prompt = ("Delete note at %s:%d?"):format(comment.file, comment.anchor.start_line),
  }, function(choice)
    if choice ~= "Delete" then
      return
    end
    local ok, error_message = store.remove(root, comment.id)
    notify_save(ok, error_message)
    render.render()
  end)
end

-- Note keys are project-relative. An absolute or expandable path is mapped back
-- onto the root so both forms can be typed at the command line.
local function as_relative(root, value)
  if not value or value == "" then
    return nil
  end
  -- Only a leading "~" is expanded. vim.fn.expand() also rewrote "$VAR", "#",
  -- "<cword>" and "{x,y}", all of which can appear in a real file name.
  local expanded = value
  if (value == "~" or value:sub(1, 2) == "~/") and vim.env.HOME then
    expanded = vim.env.HOME .. value:sub(2)
  end
  if expanded:sub(1, 1) == "/" then
    return util.relative_path(expanded, root)
  end
  -- A relative argument is still mapped through the root rather than trusted:
  -- "../elsewhere.md" would otherwise become a key no buffer can ever match,
  -- leaving the notes stored but invisible.
  return util.relative_path(util.literal_absolute_path(root, expanded), root)
end

-- The note keys of the current project, for command completion.
function M.note_paths()
  local _, _, root = current_context()
  if not root then
    return {}
  end
  local seen, result = {}, {}
  for _, comment in ipairs(store.list(root)) do
    if not seen[comment.file] then
      seen[comment.file] = true
      result[#result + 1] = comment.file
    end
  end
  table.sort(result)
  return result
end

function M.move(old, new)
  local bufnr, _, root = current_context()
  if not root then
    vim.notify(
      "contextmark: open a file in the project whose notes you want to move",
      vim.log.levels.WARN
    )
    return
  end
  local from, to = as_relative(root, old), as_relative(root, new)
  if not from or not to then
    vim.notify(
      "contextmark: both paths must be inside " .. root .. " (escape spaces as '\\ ')",
      vim.log.levels.ERROR
    )
    return
  end
  if from == to then
    vim.notify("contextmark: the source and destination are the same file", vim.log.levels.WARN)
    return
  end
  if #store.list(root, from) == 0 then
    vim.notify(("contextmark: no notes recorded for %s"):format(from), vim.log.levels.WARN)
    return
  end

  local ok, moved, error_message = store.rekey(root, from, to)
  notify_save(ok, error_message)
  if ok then
    vim.notify(
      ("contextmark: moved %d note(s) from %s to %s"):format(moved, from, to),
      vim.log.levels.INFO
    )
    render.render(bufnr)
  end
end

-- Files whose notes point at a path that no longer exists.
local function missing_files(root)
  local seen, result = {}, {}
  for _, comment in ipairs(store.list(root)) do
    if not seen[comment.file] then
      seen[comment.file] = true
      if not vim.uv.fs_stat(util.absolute_path(root, comment.file)) then
        result[#result + 1] = comment.file
      end
    end
  end
  return result
end

local scan_limit = 2000
local scan_depth = 8

-- Looks for the file a note's text actually moved to. Only runs on demand and
-- only for notes whose path is gone, so the walk never happens during editing.
local skipped_directories = { [".git"] = true, ["node_modules"] = true, [".venv"] = true }

-- One walk for every missing file. Scanning per file re-read the whole project
-- once per note, and the skip predicate has to compare basenames because
-- vim.fs.dir() passes root-relative paths below the top level.
local function find_relocations(root, missing)
  local wanted, matches = {}, {}
  for _, relative in ipairs(missing) do
    local stored = store.fingerprint(root, relative)
    if stored then
      wanted[#wanted + 1] = {
        relative = relative,
        stored = stored,
        extension = relative:match("[^./]*$") or "",
      }
      matches[relative] = {}
    end
  end
  if #wanted == 0 then
    return matches, false
  end

  local scanned, truncated = 0, false
  for name, kind in
    vim.fs.dir(root, {
      depth = scan_depth,
      skip = function(directory)
        return not skipped_directories[vim.fs.basename(directory)]
      end,
    })
  do
    if kind == "file" then
      local extension = name:match("[^./]*$") or ""
      local interesting = false
      for _, entry in ipairs(wanted) do
        if entry.extension == extension and entry.relative ~= name then
          interesting = true
          break
        end
      end
      if interesting then
        scanned = scanned + 1
        if scanned > scan_limit then
          truncated = true
          break
        end
        local lines = util.read_buffer_or_file(util.absolute_path(root, name))
        if lines then
          for _, entry in ipairs(wanted) do
            if
              entry.extension == extension
              and entry.relative ~= name
              and identity.compare(entry.stored, lines) == "same"
            then
              table.insert(matches[entry.relative], name)
            end
          end
        end
      end
    end
  end
  return matches, truncated
end

function M.relocate()
  local bufnr, _, root = current_context()
  if not root then
    vim.notify("contextmark: open a file in the project you want to search", vim.log.levels.WARN)
    return
  end

  local missing = missing_files(root)
  if #missing == 0 then
    vim.notify("contextmark: every note's file is present", vim.log.levels.INFO)
    return
  end

  local matches, capped = find_relocations(root, missing)
  local relocations = {}
  for _, relative in ipairs(missing) do
    local found = matches[relative]
    if not found then
      vim.notify(
        ("contextmark: %s has no recorded identity; use :ContextMarkMove"):format(relative),
        vim.log.levels.WARN
      )
    elseif #found == 0 then
      vim.notify(
        (
          "contextmark: could not find where %s went"
          .. " (searched %d directories deep, up to %d files%s)"
        ):format(
          relative,
          scan_depth,
          scan_limit,
          capped and ", and stopped at that limit" or ""
        ),
        vim.log.levels.WARN
      )
    else
      for _, name in ipairs(found) do
        relocations[#relocations + 1] = { from = relative, to = name }
      end
    end
  end
  if #relocations == 0 then
    return
  end

  vim.ui.select(relocations, {
    prompt = "Move notes to the file they now live in",
    format_item = function(entry)
      return ("%s -> %s"):format(entry.from, entry.to)
    end,
  }, function(entry)
    if not entry then
      return
    end
    local ok, moved, error_message = store.rekey(root, entry.from, entry.to)
    notify_save(ok, error_message)
    if not ok then
      return
    end
    -- Only one pick per run, so say what is still waiting rather than letting
    -- the rest look handled.
    local remaining = 0
    for _, candidate in ipairs(relocations) do
      if candidate.from ~= entry.from then
        remaining = remaining + 1
      end
    end
    vim.notify(
      ("contextmark: moved %d note(s) to %s%s"):format(
        moved,
        entry.to,
        remaining > 0
            and (", %d more candidate(s) left; run :ContextMarkRelocate again"):format(remaining)
          or ""
      ),
      vim.log.levels.INFO
    )
    render.render(bufnr)
  end)
end

-- Accepts the file currently at this path as the one the notes belong to. This
-- is the way out of a mismatch that is not a mistake: a wholesale rewrite looks
-- exactly like a replacement, and only the author can say which it was.
function M.reanchor()
  local bufnr, _, root, relative = current_context()
  if not bufnr then
    vim.notify("contextmark: this buffer cannot hold notes", vim.log.levels.WARN)
    return
  end
  local comments = store.list(root, relative)
  if #comments == 0 then
    vim.notify("contextmark: no notes in this buffer", vim.log.levels.WARN)
    return
  end
  if vim.bo[bufnr].modified then
    -- Re-anchoring against text that is not on disk yet cannot be undone: the
    -- old excerpt is replaced by a fragment that may never be saved.
    vim.notify(
      "contextmark: save or revert this buffer before re-anchoring against it",
      vim.log.levels.WARN
    )
    return
  end

  vim.ui.select({ "Cancel", "Accept this file" }, {
    prompt = ("Re-anchor %d note(s) against %s? The stored excerpts are replaced."):format(
      #comments,
      relative
    ),
  }, function(choice)
    if choice ~= "Accept this file" then
      return
    end
    -- The prompt may be answered long after it was asked, and by then the
    -- buffer can be gone or renamed.
    local _, current_root, current_relative = util.buffer_context(bufnr)
    if current_root ~= root or current_relative ~= relative then
      vim.notify("contextmark: this buffer changed; nothing was re-anchored", vim.log.levels.WARN)
      return
    end
    -- An asynchronous picker leaves the buffer editable while it is open.
    if vim.bo[bufnr].modified then
      vim.notify(
        "contextmark: save or revert this buffer before re-anchoring against it",
        vim.log.levels.WARN
      )
      return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local context_lines = config.get().storage.context_lines
    for _, comment in ipairs(comments) do
      local start_line, end_line, _, start_col, end_col = anchor.resolve(lines, comment.anchor)
      if start_line then
        -- Keep what the note was written against. It is the only way back if
        -- accepting this file turns out to have been the wrong call.
        comment.previous_anchor = vim.deepcopy(comment.anchor)
        if comment.anchor.kind == "line" then
          start_col, end_col = 0, #(lines[end_line] or "")
        end
        comment.anchor = anchor.capture(lines, start_line, end_line, context_lines, {
          kind = comment.anchor.kind,
          start_col = start_col,
          end_col = end_col,
        })
        comment.updated_at = util.now()
      end
    end
    store.set_fingerprint(root, relative, identity.fingerprint(lines))
    local ok, error_message = store.save(root)
    notify_save(ok, error_message)
    if ok then
      vim.notify(
        ("contextmark: re-anchored %d note(s) against %s"):format(#comments, relative),
        vim.log.levels.INFO
      )
      render.render(bufnr)
    end
  end)
end

local function has_repository(path)
  return vim.fs.root(path, { ".git" }) ~= nil
end

-- Which notes of an unattached sidecar belong to this root, and under which key.
--
-- Decided per note, from where its file actually is. Judging a whole sidecar by
-- the shape of its root path, or by some file name also existing here, offered
-- live unrelated projects for adoption (every project has a README.md) and
-- copied their notes onto this project's files.
local function adoption_plan(entry, root)
  local recorded = entry.root
  -- The previous version keyed a tree without .git on the working directory and
  -- stored a file outside it under its bare name. Such a key can only be matched
  -- by name, so that is allowed only for a sidecar that could have been written
  -- that way, and only when the name does not already exist where it was keyed.
  local by_name = not entry.missing and not has_repository(recorded)
  local prefix = root == "/" and "/" or (root .. "/")

  local cache = {}
  local function map(relative)
    if type(relative) ~= "string" or relative == "" then
      return nil
    end
    if cache[relative] ~= nil then
      return cache[relative] or nil
    end
    local mapped = false
    -- Joined literally, so a key on a link that points outside the project
    -- still counts as inside it.
    local here = util.literal_absolute_path(root, relative)
    if entry.missing then
      -- The project moved away wholesale. Its paths still hold, but only for
      -- files that exist here, and only while they stay inside this root: a
      -- key like "../x" would otherwise let prompts read outside the project.
      mapped = vim.uv.fs_stat(here) and util.relative_path(here, root) == relative and relative
        or false
    else
      local there = util.absolute_path(recorded, relative)
      if there:sub(1, #prefix) == prefix and util.project_root(there) == root then
        -- The root is derived differently now; the file stayed put.
        mapped = util.relative_path(there, root) or false
      elseif
        by_name
        and not vim.uv.fs_stat(there)
        and vim.uv.fs_stat(here)
        -- Same containment as the moved-project branch: "../x" must not match.
        and util.relative_path(here, root) == relative
      then
        mapped = relative
      end
    end
    cache[relative] = mapped
    return mapped or nil
  end

  local comments, skipped = {}, 0
  for _, comment in ipairs(entry.state.comments) do
    local relative = map(comment.file)
    if relative then
      local copy = vim.deepcopy(comment)
      copy.file = relative
      comments[#comments + 1] = copy
    else
      skipped = skipped + 1
    end
  end

  local files = {}
  for relative, fingerprint in pairs(entry.state.files or {}) do
    local mapped = map(relative)
    if mapped then
      files[mapped] = fingerprint
    end
  end
  return comments, skipped, files
end

-- Unattached sidecars holding at least one note that belongs to this root.
function M.adoption_candidates(root)
  local result = {}
  for _, entry in ipairs(store.adoptable(root)) do
    local comments, skipped, files = adoption_plan(entry, root)
    if #comments > 0 then
      entry.comments, entry.skipped, entry.files = comments, skipped, files
      entry.count = #comments
      result[#result + 1] = entry
    end
  end
  return result
end

function M.adopt()
  local _, _, root = current_context()
  if not root then
    vim.notify(
      "contextmark: open a file in the project you want to adopt notes into",
      vim.log.levels.WARN
    )
    return
  end

  local candidates = M.adoption_candidates(root)
  if #candidates == 0 then
    vim.notify("contextmark: no unattached sidecars for this project", vim.log.levels.INFO)
    return
  end

  vim.ui.select(candidates, {
    prompt = "Adopt notes into " .. root,
    format_item = function(entry)
      return ("%d note(s) recorded under %s%s"):format(
        entry.count,
        entry.root,
        entry.missing and " (no longer exists)" or ""
      )
    end,
  }, function(entry)
    if not entry then
      return
    end
    local comments, skipped, files = entry.comments, entry.skipped, entry.files
    local ok, added, error_message = store.import(root, comments, files)
    notify_save(ok, error_message)
    if not ok then
      return
    end
    -- The source sidecar is left untouched: adoption is additive so it can be
    -- repeated or undone by hand.
    vim.notify(
      ("contextmark: adopted %d note(s)%s. The original sidecar is still at %s"):format(
        added,
        skipped > 0 and (", skipped %d outside this root"):format(skipped) or "",
        entry.path
      ),
      vim.log.levels.INFO
    )
    render.render()
  end)
end

-- Where each buffer's notes lived before its name changed. Keyed by buffer
-- because :saveas fires BufFilePre/Post for two buffers, the old name and the
-- new one, and acting on the wrong one moves notes off a file that still exists.
local renaming = {}

-- A rename intent only stays live briefly. Without this a :file that correctly
-- did nothing (because the original was still on disk) stayed pending forever,
-- and an unrelated deletion hours later turned a plain buffer switch into a
-- move of somebody else's notes.
local rename_ttl_ns = 60 * 1000 * 1000 * 1000

-- A name change alone is not a rename: :saveas and :file both leave the original
-- file on disk, and its notes still belong to it. Only once the old path is gone
-- do the notes follow the buffer. LSP renames delete the old file after writing,
-- so this is retried on write and on re-entering the buffer.
local function settle_rename(bufnr)
  local before = renaming[bufnr]
  if not before then
    return
  end
  if vim.uv.hrtime() - before.at > rename_ttl_ns then
    renaming[bufnr] = nil
    return
  end
  local _, root, relative = util.buffer_context(bufnr)
  if not root or root ~= before.root or relative == before.file then
    return
  end
  if vim.uv.fs_stat(util.absolute_path(before.root, before.file)) then
    return
  end
  -- The buffer now has to hold the file those notes were written against.
  -- Otherwise this is two unrelated events that happen to line up, and moving
  -- the notes would overwrite the destination's own identity.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if identity.compare(store.fingerprint(root, before.file), lines) == "replaced" then
    renaming[bufnr] = nil
    return
  end

  renaming[bufnr] = nil
  if #store.list(root, before.file) == 0 then
    return
  end
  -- Do not take over a file that already has notes of its own. A name change
  -- does not tell us whose text the buffer holds, and merging two files' notes
  -- silently is worse than leaving them where they are.
  if #store.list(root, relative) > 0 or store.fingerprint(root, relative) then
    vim.notify(
      ("contextmark: %s already has notes, so the %d note(s) on %s were left alone"):format(
        relative,
        #store.list(root, before.file),
        before.file
      ) .. " (use :ContextMarkMove to move them)",
      vim.log.levels.WARN
    )
    return
  end
  local ok, moved, error_message = store.rekey(root, before.file, relative)
  notify_save(ok, error_message)
  if ok and moved > 0 then
    vim.notify(
      ("contextmark: followed %s to %s with %d note(s)"):format(before.file, relative, moved),
      vim.log.levels.INFO
    )
    render.render(bufnr)
  end
end

-- Keys written before a symlinked file was resolved to its target. The previous
-- version stored "alias.md" for a link to "real.md" in the same project; this
-- version keys the buffer as "real.md", so those notes were stored but shown
-- nowhere, and no command could reach them (Move and Relocate both resolve the
-- old key to the new one and see nothing to do). Checked once per root.
-- Marked done only once every re-key has been saved, so a transient failure
-- (another instance holding the lock) is retried on the next BufEnter. The
-- error is reported once per root, or it would repeat on every buffer switch.
local canonicalized = {}
local canonicalize_reported = {}

function canonicalize_keys(bufnr)
  local _, root = util.buffer_context(bufnr)
  if not root or canonicalized[root] then
    return
  end

  local renames, order = {}, {}
  for _, comment in ipairs(store.list(root)) do
    local file = comment.file
    if type(file) == "string" and file ~= "" and renames[file] == nil then
      -- Joined literally: resolving here is exactly what hides the old key.
      local literal = (root == "/" and "" or root) .. "/" .. file
      local current = vim.uv.fs_stat(literal) and util.relative_path(literal, root)
      if current and current ~= file then
        renames[file] = current
        order[#order + 1] = file
      else
        renames[file] = false
      end
    end
  end

  local moved, failure = 0, nil
  for _, file in ipairs(order) do
    local ok, count, error_message = store.rekey(root, file, renames[file])
    if ok then
      moved = moved + count
    else
      failure = failure or error_message
    end
  end
  if failure then
    if not canonicalize_reported[root] then
      canonicalize_reported[root] = true
      notify_save(false, failure)
    end
  else
    canonicalized[root] = true
    canonicalize_reported[root] = nil
  end
  if moved > 0 then
    vim.notify(
      ("contextmark: re-keyed %d note(s) recorded under a symlinked path"):format(moved),
      vim.log.levels.INFO
    )
  end
end

-- Announced once per root per session, and only when this project has no notes
-- of its own: a silent empty sidecar is indistinguishable from "no notes yet".
local announced = {}

local function announce_adoptable(bufnr)
  local _, root = util.buffer_context(bufnr)
  if not root or announced[root] then
    return
  end
  announced[root] = true
  if #store.list(root) > 0 then
    return
  end
  local candidates = M.adoption_candidates(root)
  local total, sidecars = 0, 0
  for _, entry in ipairs(candidates) do
    -- A project that merely vanished somewhere else is not announced: its notes
    -- can only be matched here by path, which is too weak to warn about unasked.
    if not entry.missing then
      total = total + entry.count
      sidecars = sidecars + 1
    end
  end
  if total == 0 then
    return
  end
  vim.notify(
    ("contextmark: %d note(s) in %d sidecar(s) are not attached to this project root."):format(
      total,
      sidecars
    ) .. " Run :ContextMarkAdopt to review them.",
    vim.log.levels.WARN
  )
end

-- render() judges a file's identity when its buffer is open. A note whose file
-- is closed has never been checked against what is on disk now, so a branch
-- switch or an agent rewriting the file while it was closed reached the prompt
-- as a healthy note quoting the replacement's text. Judge those here, once per
-- file, and flag them for this prompt only: the sidecar still describes the
-- note's own file, and the flag disappears by itself if the file comes back.
local function flag_replaced_closed_files(root, comments)
  local verdicts = {}
  local result = {}
  for index, comment in ipairs(comments) do
    local relative = comment.file
    if verdicts[relative] == nil then
      local path = util.absolute_path(root, relative)
      -- Strict lookup: vim.fn.bufnr() matches names as patterns, so asking for
      -- "a.md" could find "a.md.bak" and skip the file that was replaced.
      local open = util.buffer_for(path) ~= nil
      local lines = not open
        and store.fingerprint(root, relative)
        and util.read_buffer_or_file(path)
      -- A file that is gone is not a replacement: Relocate handles that.
      verdicts[relative] = type(lines) == "table"
        and render.judge(root, relative, lines, store.list(root, relative)) == "replaced"
    end
    if verdicts[relative] and comment.anchor.status ~= "mismatch" then
      comment = vim.deepcopy(comment)
      comment.anchor.status = "mismatch"
    end
    result[index] = comment
  end
  return result
end

local function comments_for(scope)
  render.sync_all()
  local _, _, root, relative = current_context()
  if not root then
    return nil, {}
  end
  local comments
  if scope == "current" then
    local comment = render.at_cursor()
    comments = comment and { comment } or {}
  elseif scope == "buffer" then
    comments = store.list(root, relative)
  else
    comments = store.list(root)
  end
  return root, flag_replaced_closed_files(root, comments)
end

local function deliver(root, comments, mode)
  if #comments == 0 then
    vim.notify("contextmark: no comments for this scope", vim.log.levels.WARN)
    return nil
  end
  local text = prompt.build(root, comments)
  local ok, result = delivery.send(text, comments, mode)
  if not ok then
    vim.notify(
      "contextmark: could not deliver prompt: " .. (result.error or "unknown error"),
      vim.log.levels.ERROR
    )
    return nil, result
  end

  local routes = {}
  if result.direct.ok then
    routes[#routes + 1] = "direct"
  end
  if result.clipboard.ok then
    local label = result.clipboard.register == '"' and "Neovim register" or "clipboard"
    routes[#routes + 1] = label
  end
  local fallback = result.fallback and " (direct unavailable; fallback used)" or ""
  vim.notify(
    ("contextmark: delivered %d note(s) via %s%s"):format(
      #comments,
      table.concat(routes, " + "),
      fallback
    ),
    vim.log.levels.INFO
  )
  return text, result
end

function M.build_prompt(scope)
  local root, comments = comments_for(scope or "all")
  if not root or #comments == 0 then
    return nil, comments
  end
  return prompt.build(root, comments), comments
end

function M.export(scope, mode)
  scope = scope or "all"
  if not vim.tbl_contains({ "current", "buffer", "all", "select" }, scope) then
    vim.notify("contextmark: unknown prompt scope: " .. tostring(scope), vim.log.levels.ERROR)
    return
  end
  local root, comments = comments_for(scope)
  if scope == "select" then
    ui.select(comments, function(selected)
      deliver(root, selected, mode)
    end)
    return
  end
  return deliver(root, comments, mode)
end

function M.list()
  render.sync_all()
  local _, _, root = current_context()
  if not root then
    return
  end
  local items = {}
  for _, comment in ipairs(store.list(root)) do
    items[#items + 1] = {
      filename = util.absolute_path(root, comment.file),
      lnum = comment.anchor.start_line,
      end_lnum = comment.anchor.end_line,
      text = comment.body:gsub("\n", " "),
    }
  end
  vim.fn.setqflist({}, " ", { title = "contextmark", items = items })
  vim.cmd.copen()
end

function M.show(silent)
  local comments = render.at_cursor_all()
  if #comments == 0 then
    ui.close_hover()
    if not silent then
      vim.notify("contextmark: no comments at cursor", vim.log.levels.INFO)
    end
    return nil
  end
  return ui.hover(comments)
end

function M.goto_comment(direction)
  local _, _, root, relative = current_context()
  if not root then
    return
  end
  local comments = store.list(root, relative)
  if #comments == 0 then
    vim.notify("contextmark: no comments in this buffer", vim.log.levels.INFO)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  if direction > 0 then
    for _, comment in ipairs(comments) do
      if comment.anchor.start_line > cursor then
        vim.api.nvim_win_set_cursor(0, { comment.anchor.start_line, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { comments[1].anchor.start_line, 0 })
  else
    for index = #comments, 1, -1 do
      if comments[index].anchor.start_line < cursor then
        vim.api.nvim_win_set_cursor(0, { comments[index].anchor.start_line, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { comments[#comments].anchor.start_line, 0 })
  end
end

map_buffer = function(bufnr)
  local keys = config.get().keymaps
  local function map(modes, lhs, callback, description)
    if type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set(modes, lhs, callback, { buffer = bufnr, silent = true, desc = description })
    end
  end
  map({ "n", "v" }, keys.add, M.add, "Markdown note: add")
  map("n", keys.edit, M.edit, "Markdown note: edit")
  map("n", keys.delete, M.delete, "Markdown note: delete")
  map("n", keys.show, M.show, "Markdown note: show")
  map("n", keys.next, function()
    M.goto_comment(1)
  end, "Markdown note: next")
  map("n", keys.prev, function()
    M.goto_comment(-1)
  end, "Markdown note: previous")
  map("n", keys.list, M.list, "Markdown note: list")
  map("n", keys.prompt_current, function()
    M.export("current")
  end, "Markdown note: prompt current")
  map("n", keys.prompt_buffer, function()
    M.export("buffer")
  end, "Markdown note: prompt buffer")
  map("n", keys.prompt_all, function()
    M.export("all")
  end, "Markdown note: prompt all")
  map("n", keys.prompt_select, function()
    M.export("select")
  end, "Markdown note: prompt select")
end

function M.setup(opts)
  config.setup(opts)
  vim.api.nvim_set_hl(0, "ContextMarkSign", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(
    0,
    "ContextMarkVirtualText",
    { link = "DiagnosticVirtualTextInfo", default = true }
  )
  vim.api.nvim_set_hl(0, "ContextMarkRange", { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "ContextMarkStale", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "ContextMarkStaleRange", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "ContextMarkMismatch", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "ContextMarkMismatchRange", { link = "DiagnosticError", default = true })

  local group = vim.api.nvim_create_augroup("contextmark", { clear = true })
  -- Matched here rather than through the autocmd pattern so that globs and
  -- predicate functions in `filetypes` behave identically across every event.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "*",
    callback = function(event)
      initialize_buffer(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(event)
      if util.is_filetype_allowed(vim.bo[event.buf].filetype, config.get().filetypes) then
        settle_rename(event.buf)
        canonicalize_keys(event.buf)
        render.render(event.buf)
        announce_adoptable(event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      if util.is_filetype_allowed(vim.bo[event.buf].filetype, config.get().filetypes) then
        settle_rename(event.buf)
        render.sync(event.buf)
        render.render(event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group,
    callback = function(event)
      -- Give a rename that is already pending its chance before replacing it,
      -- so two renames in a row do not lose the first one's origin.
      settle_rename(event.buf)
      local _, root, relative = util.buffer_context(event.buf)
      renaming[event.buf] = root and { root = root, file = relative, at = vim.uv.hrtime() } or nil
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(event)
      settle_rename(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      renaming[event.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function(event)
      if
        config.get().display.hover
        and util.is_filetype_allowed(vim.bo[event.buf].filetype, config.get().filetypes)
      then
        M.show(true)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" }, {
    group = group,
    callback = ui.close_hover,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      initialize_buffer(bufnr)
    end
  end
  configured = true
end

function M.is_configured()
  return configured
end

return M
