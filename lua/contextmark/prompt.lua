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
  local lines = util.read_buffer_or_file(util.absolute_path(root, comment.file))
  if lines then
    local start_line = math.max(1, math.min(comment.anchor.start_line, #lines))
    local end_line = math.max(start_line, math.min(comment.anchor.end_line, #lines))
    return start_line,
      end_line,
      anchor.extract(lines, start_line, end_line, comment.anchor.start_col, comment.anchor.end_col)
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
