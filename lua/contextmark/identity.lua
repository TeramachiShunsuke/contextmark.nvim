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

-- Below this many samples nothing can be concluded: a short file shares its
-- heading with any other short file, so both accusing and clearing it would be
-- guesswork.
local ratio_floor = 10

-- A file has to lose more than nine tenths of its lines to be called a
-- different file. The cost of the two mistakes is not symmetric: a missed
-- replacement is caught later by the excerpt no longer matching, while a false
-- accusation flags every note in a file the author is simply rewriting.
local survival_denominator = 10

-- At or below this share of the recorded sample, a "same" rests on what every
-- document of its kind carries -- front matter, headings, a licence -- and must
-- not be trusted on its own: render asks the notes, Relocate does not follow it.
M.weak_share = 0.5

-- Below this many recorded paragraphs the wrap-independent check has too little
-- to say: one shared paragraph out of two would clear any file.
local paragraph_sample_floor = 4

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

-- The digest of a line's canonical form, remembered by the raw line. Hashing
-- every line of a 50,000-line file took about 110 ms, and it happened again on
-- the first render after every edit and after every :w, although an edit
-- changes only a few lines. Cleared when it grows, so it stays bounded.
local line_digests, line_digest_count = {}, 0
local line_digest_limit = 200000

local function line_digest(line)
  local cached = line_digests[line]
  if cached == nil then
    if line_digest_count >= line_digest_limit then
      line_digests, line_digest_count = {}, 0
    end
    cached = digest(canonical(line))
    line_digests[line] = cached
    line_digest_count = line_digest_count + 1
  end
  return cached
end

-- Digests of the distinct canonical lines, in document order. Repeats are
-- dropped because a file with a repeating structure (a table, a command list)
-- would otherwise fill the whole sample with one digest and match any other
-- file sharing that single line. Blank lines are dropped for the same reason --
-- they match anything -- though with distinctness in place they could only ever
-- contribute one entry, so that part is clarity rather than a load-bearing rule.
local function significant(lines)
  local seen, result = {}, {}
  for _, line in ipairs(lines) do
    if line:match("%S") then
      local value = line_digest(line)
      if not seen[value] then
        seen[value] = true
        result[#result + 1] = value
      end
    end
  end
  return result
end

-- Spread the sample evenly across the document by position. Walking with a
-- floor()ed step instead made the sample run out inside the first 32 lines for
-- any document with 33 to 63 significant lines -- the most ordinary size there
-- is -- which weighted the opening of the file at the expense of everything
-- after it. That is backwards twice over: rewriting an introduction looked like
-- a new document, while two unrelated documents sharing a licence header or
-- front matter looked like the same one.
local function sample_of(body)
  local taken = math.min(sample_size, #body)
  local sample = {}
  if taken == 1 then
    sample[1] = body[1]
    return sample
  end
  for step = 1, taken do
    local index = 1 + math.floor((step - 1) * (#body - 1) / (taken - 1) + 0.5)
    sample[#sample + 1] = body[index]
  end
  return sample
end

-- Prose paragraphs survive a change of wrap width; lines do not. A paragraph is
-- a run of non-blank lines joined into one string, so re-wrapping the same words
-- leaves its digest untouched.
--
-- Only paragraphs with some substance count. A heading, a "---" rule or a lone
-- list marker is its own paragraph and recurs across unrelated documents built
-- from the same template, so counting those would call any two of them the same
-- file.
-- And nothing above the ceiling: a file with no blank lines is one "paragraph"
-- of its whole self, which is neither prose nor worth hashing on every render.
local paragraph_floor = 60
local paragraph_ceiling = 4000

local function paragraph_digests(lines)
  local seen, result = {}, {}
  local current, length = {}, 0
  local function flush()
    -- Measured while collecting: a file with no blank lines would otherwise
    -- concatenate itself in full on every render just to be discarded here.
    if length >= paragraph_floor and length <= paragraph_ceiling then
      local value = line_digest(table.concat(current, " "))
      if not seen[value] then
        seen[value] = true
        result[#result + 1] = value
      end
    end
    current, length = {}, 0
  end
  for _, line in ipairs(lines) do
    if line:match("%S") then
      if length <= paragraph_ceiling then
        current[#current + 1] = line
      end
      length = length + #line + (length > 0 and 1 or 0)
    else
      flush()
    end
  end
  flush()
  return result
end

-- Returns the fingerprint and the line digests it was built from, so a
-- comparison does not walk the document twice.
local function describe(lines)
  local body = significant(lines)
  local paragraphs = paragraph_digests(lines)
  local current = {
    digest = digest(table.concat(lines, "\n")),
    lines = #lines,
    significant = #body,
    sample = sample_of(body),
    paragraphs = next(paragraphs) and sample_of(paragraphs) or nil,
  }
  return current, body, paragraphs
end

function M.fingerprint(lines)
  return (describe(lines))
end

-- Returns "same" / "replaced" / "unknown" plus the fingerprint of `lines`.
-- "unknown" means no conclusion, which is the state of every note written
-- before fingerprints existed and of every file too short to judge; callers
-- must treat it as "do not accuse this file" rather than as a replacement.
-- How many of `stored` are still present.
local function hits_in(stored, present)
  local hits = 0
  for _, entry in ipairs(stored) do
    if present[entry] then
      hits = hits + 1
    end
  end
  return hits
end

local function survives(stored, present)
  return hits_in(stored, present) * survival_denominator >= #stored
end

local function set_of(values)
  local result = {}
  for _, value in ipairs(values) do
    result[value] = true
  end
  return result
end

-- Returns "same" / "replaced" / "unknown", the fingerprint of `lines`, and how
-- much of the recorded sample survived (nil when nothing was decided). The
-- caller uses that share to tell a file it barely recognises -- two documents
-- from one template share their boilerplate -- from one it plainly knows.
function M.compare(stored, lines)
  local current, body, paragraphs = describe(lines)
  if type(stored) ~= "table" or type(stored.sample) ~= "table" then
    return "unknown", current
  end
  if stored.digest and stored.digest == current.digest then
    return "same", current, 1
  end

  local total = #stored.sample
  if total < ratio_floor then
    return "unknown", current
  end
  -- Nothing but blank lines: no text to recognise or to accuse. The file was
  -- cleared, which anchor.resolve() reports as "orphaned".
  if #body == 0 then
    return "unknown", current
  end

  local hits = hits_in(stored.sample, set_of(body))
  if hits * survival_denominator >= total then
    return "same", current, hits / total
  end

  -- No line survived, which is also what re-wrapping the whole file looks like.
  -- Paragraphs are wrap-independent, so ask them before calling this a different
  -- file. Fingerprints written before paragraphs were recorded have none, and
  -- are judged by their lines alone.
  if type(stored.paragraphs) == "table" and #stored.paragraphs >= paragraph_sample_floor then
    local paragraph_hits = hits_in(stored.paragraphs, set_of(paragraphs))
    if paragraph_hits * survival_denominator >= #stored.paragraphs then
      -- Report the paragraphs' share, not a blanket 1: a single shared licence
      -- paragraph clears two unrelated documents here, and the caller only asks
      -- the notes when the share is low.
      return "same", current, paragraph_hits / #stored.paragraphs
    end
  end
  return "replaced", current, hits / total
end

-- Whether two lines are the same text, compared the way the fingerprint compares
-- them (whitespace amounts ignored). Blank lines are never a match: they are
-- beside everything.
function M.same_line(left, right)
  return type(left) == "string"
    and type(right) == "string"
    and left:match("%S") ~= nil
    and line_digest(left) == line_digest(right)
end

return M
