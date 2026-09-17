-- Persistent text-range anchors for contextmark.nvim.
local M = {}

local function slice(lines, first, last)
  local result = {}
  first = math.max(first, 1)
  last = math.min(last, #lines)
  for index = first, last do
    result[#result + 1] = lines[index]
  end
  return result
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(value, maximum))
end

function M.extract(lines, start_line, end_line, start_col, end_col)
  if #lines == 0 then
    return {}
  end
  start_line = clamp(start_line, 1, #lines)
  end_line = clamp(end_line, start_line, #lines)
  start_col = clamp(start_col or 0, 0, #(lines[start_line] or ""))
  end_col = clamp(end_col or #(lines[end_line] or ""), 0, #(lines[end_line] or ""))

  local result = slice(lines, start_line, end_line)
  if start_line == end_line then
    result[1] = (lines[start_line] or ""):sub(start_col + 1, end_col)
    return result
  end
  result[1] = (lines[start_line] or ""):sub(start_col + 1)
  result[#result] = (lines[end_line] or ""):sub(1, end_col)
  return result
end

function M.capture(lines, start_line, end_line, context_lines, range)
  start_line = clamp(start_line, 1, #lines)
  end_line = clamp(end_line, start_line, #lines)
  context_lines = context_lines or 2
  range = range or {}
  local start_col = clamp(range.start_col or 0, 0, #(lines[start_line] or ""))
  local end_col = clamp(range.end_col or #(lines[end_line] or ""), 0, #(lines[end_line] or ""))

  return {
    kind = range.kind or "line",
    start_line = start_line,
    end_line = end_line,
    start_col = start_col,
    end_col = end_col,
    excerpt = M.extract(lines, start_line, end_line, start_col, end_col),
    before = slice(lines, start_line - context_lines, start_line - 1),
    after = slice(lines, end_line + 1, end_line + context_lines),
    prefix = (lines[start_line] or ""):sub(1, start_col),
    suffix = (lines[end_line] or ""):sub(end_col + 1),
    status = "exact",
  }
end

local function match_at(lines, excerpt, start_line, start_col)
  if #excerpt == 0 or start_line < 1 or start_line + #excerpt - 1 > #lines then
    return nil
  end
  if #excerpt == 1 then
    local end_col = start_col + #excerpt[1]
    if (lines[start_line] or ""):sub(start_col + 1, end_col) == excerpt[1] then
      return start_line, end_col
    end
    return nil
  end

  if (lines[start_line] or ""):sub(start_col + 1) ~= excerpt[1] then
    return nil
  end
  for index = 2, #excerpt - 1 do
    if lines[start_line + index - 1] ~= excerpt[index] then
      return nil
    end
  end
  local end_line = start_line + #excerpt - 1
  if (lines[end_line] or ""):sub(1, #excerpt[#excerpt]) ~= excerpt[#excerpt] then
    return nil
  end
  return end_line, #excerpt[#excerpt]
end

-- Ranks a candidate position. This score cannot tell "moved" from "wrong file":
-- an empty prefix and suffix both match trivially and are worth four points, and
-- the blank lines that surround most Markdown paragraphs match anywhere, so a
-- candidate in a completely unrelated file never scores zero. Deciding whether
-- the file itself is still the right one belongs to identity.lua.
local function context_score(lines, stored, start_line, end_line, start_col, end_col)
  local score = 0
  local before = stored.before or {}
  local after = stored.after or {}
  for index, value in ipairs(before) do
    local line_index = start_line - #before + index - 1
    if line_index >= 1 and lines[line_index] == value then
      score = score + 1
    end
  end
  for index, value in ipairs(after) do
    local line_index = end_line + index
    if line_index <= #lines and lines[line_index] == value then
      score = score + 1
    end
  end
  if stored.prefix and (lines[start_line] or ""):sub(1, start_col) == stored.prefix then
    score = score + 2
  end
  if stored.suffix and (lines[end_line] or ""):sub(end_col + 1) == stored.suffix then
    score = score + 2
  end
  return score
end

local function is_effectively_empty(lines)
  return #lines == 0 or (#lines == 1 and lines[1] == "")
end

local function candidates(lines, excerpt)
  local result = {}
  if #excerpt == 1 and excerpt[1] ~= "" then
    for line_number, line in ipairs(lines) do
      local from = 1
      while from <= #line + 1 do
        local first, last = line:find(excerpt[1], from, true)
        if not first then
          break
        end
        result[#result + 1] = {
          start_line = line_number,
          end_line = line_number,
          start_col = first - 1,
          end_col = last,
        }
        from = first + 1
      end
    end
    return result
  end

  if #excerpt > 1 then
    for start_line, line in ipairs(lines) do
      local first = excerpt[1]
      local start_col = #line - #first
      if start_col >= 0 then
        local end_line, end_col = match_at(lines, excerpt, start_line, start_col)
        if end_line then
          result[#result + 1] = {
            start_line = start_line,
            end_line = end_line,
            start_col = start_col,
            end_col = end_col,
          }
        end
      end
    end
  end
  return result
end

function M.resolve(lines, stored)
  -- Report an empty file as a resolvable position rather than nil. Returning nil
  -- made render.lua drop the note entirely, so "orphaned" was unreachable and
  -- the note silently vanished instead of being flagged.
  if is_effectively_empty(lines) then
    return 1, 1, "orphaned", 0, 0
  end

  local excerpt = stored.excerpt or {}
  local original_line = clamp(stored.start_line or 1, 1, #lines)
  local original_col = clamp(stored.start_col or 0, 0, #(lines[original_line] or ""))
  local exact_end_line, exact_end_col = match_at(lines, excerpt, original_line, original_col)
  if exact_end_line then
    return original_line, exact_end_line, "exact", original_col, exact_end_col
  end

  local matches = candidates(lines, excerpt)
  for _, match in ipairs(matches) do
    match.score =
      context_score(lines, stored, match.start_line, match.end_line, match.start_col, match.end_col)
    match.distance = math.abs(match.start_line - original_line)
      + math.abs(match.start_col - original_col)
  end
  table.sort(matches, function(left, right)
    if left.score ~= right.score then
      return left.score > right.score
    end
    return left.distance < right.distance
  end)
  if matches[1] then
    local winner, runner_up = matches[1], matches[2]
    local tied = runner_up
      and runner_up.score == winner.score
      and runner_up.distance == winner.distance
    if not tied then
      return winner.start_line, winner.end_line, "moved", winner.start_col, winner.end_col
    end
  end

  local line_span = math.max(#excerpt, (stored.end_line or original_line) - original_line + 1)
  local fallback_end_line = math.min(original_line + line_span - 1, #lines)
  local fallback_start_col = clamp(stored.start_col or 0, 0, #(lines[original_line] or ""))
  local fallback_end_col =
    clamp(stored.end_col or #(lines[fallback_end_line] or ""), 0, #(lines[fallback_end_line] or ""))
  return original_line, fallback_end_line, "stale", fallback_start_col, fallback_end_col
end

function M.slice(lines, start_line, end_line)
  return slice(lines, start_line, end_line)
end

return M
