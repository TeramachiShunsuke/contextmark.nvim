-- File identity for contextmark.nvim.
--
-- Whether a note still belongs to the file sitting at its path cannot be decided
-- from the note's own surrounding lines. Blank lines and template lines ("##
-- Overview", "- [ ] todo") recur across unrelated documents, so a note-local
-- context check either misses a replacement or flags a heading rename as one.
--
-- This module decides it per file instead, by comparing the file against a
-- fingerprint taken while the file was known to be the right one. An edit keeps
-- most of its lines; a different file that happens to occupy the same path keeps
-- almost none.
local M = {}

-- Enough lines to make the ratio meaningful without storing the document.
local sample_size = 32

-- Below this many samples a ratio means nothing, so only "nothing survived"
-- decides.
local ratio_floor = 10

-- A file has to lose more than nine tenths of its lines to be called a
-- different file. The cost of the two mistakes is not symmetric: a missed
-- replacement is caught later by the excerpt no longer matching, while a false
-- accusation flags every note in a file the author is simply rewriting.
local survival_denominator = 10

local function digest(text)
  -- vim.fn.sha256() turns a string containing NUL into a Blob and raises E976.
  local safe = text:gsub("%z", "\n")
  return vim.fn.sha256(safe):sub(1, 32)
end

-- Identity has to survive reformatting. Trailing whitespace removal on save and
-- a re-indent change every line of a file without changing a word of it, and
-- treating those as a new document would flag every note in the file.
local function canonical(line)
  local trimmed = line:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return trimmed
end

-- Distinct canonical lines in document order. Blank lines are dropped because
-- they match anything, and repeats are dropped because a file with a repeating
-- structure (a table, a command list) would otherwise fill the whole sample
-- with one digest and match any other file sharing that single line.
local function significant(lines)
  local seen, result = {}, {}
  for _, line in ipairs(lines) do
    if line:match("%S") then
      local value = canonical(line)
      if not seen[value] then
        seen[value] = true
        result[#result + 1] = value
      end
    end
  end
  return result
end

function M.fingerprint(lines)
  local body = significant(lines)
  local sample = {}
  if #body > 0 then
    -- Spread the sample across the whole document: a prefix would miss an
    -- append-only edit and over-weight a shared header.
    local step = math.max(1, math.floor(#body / sample_size))
    for index = 1, #body, step do
      sample[#sample + 1] = digest(body[index])
      if #sample >= sample_size then
        break
      end
    end
  end
  return {
    digest = digest(table.concat(lines, "\n")),
    lines = #lines,
    significant = #body,
    sample = sample,
  }
end

-- Returns "same" / "replaced" / "unknown" plus the fingerprint of `lines`.
-- "unknown" means there is nothing to compare against yet, which is the state of
-- every note written before fingerprints existed; callers must treat it as "do
-- not accuse this file" rather than as a replacement.
function M.compare(stored, lines)
  local current = M.fingerprint(lines)
  if type(stored) ~= "table" or type(stored.sample) ~= "table" then
    return "unknown", current
  end
  if stored.digest and stored.digest == current.digest then
    return "same", current
  end

  local present = {}
  for _, value in ipairs(significant(lines)) do
    present[digest(value)] = true
  end
  local hits = 0
  for _, entry in ipairs(stored.sample) do
    if present[entry] then
      hits = hits + 1
    end
  end

  local total = #stored.sample
  if total == 0 then
    return "unknown", current
  end
  if total < ratio_floor then
    return hits == 0 and "replaced" or "same", current
  end
  return hits * survival_denominator < total and "replaced" or "same", current
end

return M
