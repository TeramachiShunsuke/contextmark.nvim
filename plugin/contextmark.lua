if vim.g.loaded_contextmark then
  return
end
vim.g.loaded_contextmark = true

local function module()
  return require("contextmark")
end

vim.api.nvim_create_user_command("ContextMarkAdd", function()
  module().add()
end, {})

vim.api.nvim_create_user_command("ContextMarkEdit", function()
  module().edit()
end, {})

vim.api.nvim_create_user_command("ContextMarkDelete", function()
  module().delete()
end, {})

vim.api.nvim_create_user_command("ContextMarkList", function()
  module().list()
end, {})

vim.api.nvim_create_user_command("ContextMarkAdopt", function()
  module().adopt()
end, {})

vim.api.nvim_create_user_command("ContextMarkMove", function(args)
  if #args.fargs ~= 2 then
    vim.notify(
      "contextmark: usage :ContextMarkMove {old path} {new path} (escape spaces as '\\ ')",
      vim.log.levels.ERROR
    )
    return
  end
  module().move(args.fargs[1], args.fargs[2])
end, { nargs = "+", complete = "file" })

vim.api.nvim_create_user_command("ContextMarkRelocate", function()
  module().relocate()
end, {})

vim.api.nvim_create_user_command("ContextMarkReanchor", function()
  module().reanchor()
end, {})

vim.api.nvim_create_user_command("ContextMarkShow", function()
  module().show()
end, {})

vim.api.nvim_create_user_command("ContextMarkSend", function(args)
  module().export(args.fargs[1] or "all", args.fargs[2])
end, {
  nargs = "*",
  complete = function(_, command_line)
    local words = vim.split(command_line, "%s+", { trimempty = true })
    if #words <= 1 then
      return { "current", "buffer", "all", "select" }
    end
    if #words == 2 and not command_line:match("%s$") then
      return { "current", "buffer", "all", "select" }
    end
    return { "auto", "direct", "clipboard", "both" }
  end,
})

vim.api.nvim_create_user_command("ContextMarkSendDirect", function(args)
  module().export(args.args ~= "" and args.args or "all", "direct")
end, {
  nargs = "?",
  complete = function()
    return { "current", "buffer", "all", "select" }
  end,
})

vim.api.nvim_create_user_command("ContextMarkSendClipboard", function(args)
  module().export(args.args ~= "" and args.args or "all", "clipboard")
end, {
  nargs = "?",
  complete = function()
    return { "current", "buffer", "all", "select" }
  end,
})
