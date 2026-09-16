local anchor = require("contextmark.anchor")
local util = require("contextmark.util")

local M = {}

local function source_name(comment)
  local filetype = comment.filetype or ""
  if filetype == "markdown" or filetype == "markdown.mdx" or comment.file:match("%.mdx?$") then
    return "markdown"
  end
  return filetype ~= "" and filetype or "text"
end

local function comment_excerpt(root, comment)
  -- An unresolved note must quote the text it was written against rather than
  -- whatever now occupies its coordinates. Re-extracting from a replacement file
  -- hands the agent another document's line as the user's selection, and
  -- re-extracting from a range that collapsed after an edit yields an empty
  -- quote that points at nothing.
  if util.is_warning_status(comment.anchor.status) then
    return comment.anchor.start_line, comment.anchor.end_line, comment.anchor.excerpt or {}
  end

  local lines = util.read_buffer_or_file(util.absolute_path(root, comment.file))
  if lines then
    local start_line = math.max(1, math.min(comment.anchor.start_line, #lines))
    local end_line = math.max(start_line, math.min(comment.anchor.end_line, #lines))
    local excerpt =
      anchor.extract(lines, start_line, end_line, comment.anchor.start_col, comment.anchor.end_col)
    -- An empty quote tells the agent nothing about what the note is for. Fall
    -- back to the stored text rather than sending "Excerpt:" with a bare ">".
    for _, line in ipairs(excerpt) do
      if line:match("%S") then
        return start_line, end_line, excerpt
      end
    end
  end
  return comment.anchor.start_line, comment.anchor.end_line, comment.anchor.excerpt or {}
end

function M.build(root, comments)
  local sorted = vim.deepcopy(comments)
  table.sort(sorted, function(left, right)
    if left.file ~= right.file then
      return left.file < right.file
    end
    return left.anchor.start_line < right.anchor.start_line
  end)

  local output = {}
  local active_file
  local first_comment_in_file = true

  for _, comment in ipairs(sorted) do
    if active_file ~= comment.file then
      if #output > 0 then
        output[#output + 1] = ""
      end
      active_file = comment.file
      first_comment_in_file = true
      output[#output + 1] = "File: " .. comment.file
      output[#output + 1] = "Source: " .. source_name(comment)
      output[#output + 1] = ""
    elseif not first_comment_in_file then
      output[#output + 1] = ""
    end

    local start_line, end_line, excerpt = comment_excerpt(root, comment)
    output[#output + 1] = util.range_label(start_line, end_line)
    -- Healthy notes keep the exact Orca shape; only an unresolved one gains a
    -- line, so the contract the tests pin stays byte-identical.
    local status_note = util.status_note(comment.anchor.status)
    if status_note then
      output[#output + 1] = status_note
    end
    output[#output + 1] = "Excerpt:"
    for _, line in ipairs(excerpt) do
      output[#output + 1] = line == "" and ">" or "> " .. line
    end
    output[#output + 1] = "User comment: " .. vim.json.encode(comment.body)
    first_comment_in_file = false
  end

  return table.concat(output, "\n")
end

return M
