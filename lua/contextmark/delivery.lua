local config = require("contextmark.config")

local M = {}

local valid_modes = {
  auto = true,
  direct = true,
  clipboard = true,
  both = true,
}

local function resolve_direct()
  local configured = config.get().delivery.direct
  if type(configured.send) == "function" then
    return configured
  end

  local requested = configured.adapter or "auto"
  if requested == false or requested == "none" then
    return nil, "direct adapter is disabled"
  end
  local candidates = requested == "auto" and { "sidekick" } or { requested }
  local reasons = {}

  for _, name in ipairs(candidates) do
    local loaded, candidate = pcall(require, "contextmark.adapters." .. name)
    if loaded then
      local checked, available, reason = pcall(candidate.is_available)
      if checked and available then
        return {
          is_available = candidate.is_available,
          send = function(text, comments)
            return candidate.send(text, comments, configured)
          end,
        }
      end
      reasons[#reasons + 1] = checked and (reason or (name .. " is unavailable"))
        or (name .. " check failed: " .. tostring(available))
    else
      reasons[#reasons + 1] = name .. " adapter could not load: " .. tostring(candidate)
    end
  end
  return nil, table.concat(reasons, "; ")
end

local function direct_send(text, comments)
  local adapter, resolve_reason = resolve_direct()
  if not adapter then
    return false, resolve_reason or "direct adapter is not configured"
  end

  if type(adapter.is_available) == "function" then
    local checked, available, reason = pcall(adapter.is_available)
    if not checked then
      return false, "availability check failed: " .. tostring(available)
    end
    if not available then
      return false, reason or "direct adapter is unavailable"
    end
  end

  local called, response, reason = pcall(adapter.send, text, comments)
  if not called then
    return false, "direct send failed: " .. tostring(response)
  end
  if response == false then
    return false, reason or "direct adapter rejected the prompt"
  end
  if type(response) == "table" and response.accepted == false then
    return false, response.reason or "direct adapter did not accept the prompt"
  end
  return true
end

local function set_register(register, text)
  if type(register) ~= "string" or register == "" then
    return false, "clipboard register is not configured"
  end
  if (register == "+" or register == "*") and vim.fn.has("clipboard") == 0 then
    return false, "Neovim clipboard provider is unavailable"
  end
  local ok, error_message = pcall(vim.fn.setreg, register, text)
  if not ok then
    return false, tostring(error_message)
  end
  return true
end

local function clipboard_send(text)
  local clipboard = config.get().delivery.clipboard
  local ok, reason = set_register(clipboard.register, text)
  if ok then
    return true, nil, clipboard.register
  end

  if clipboard.fallback_register and clipboard.fallback_register ~= clipboard.register then
    local fallback_ok, fallback_reason = set_register(clipboard.fallback_register, text)
    if fallback_ok then
      return true, ("system clipboard unavailable (%s)"):format(reason), clipboard.fallback_register
    end
    return false, ("%s; fallback register failed: %s"):format(reason, fallback_reason)
  end
  return false, reason
end

function M.send(text, comments, requested_mode)
  local settings = config.get().delivery
  local mode = requested_mode or settings.mode or "auto"
  if not valid_modes[mode] then
    return false, { mode = mode, error = "unknown delivery mode: " .. tostring(mode) }
  end

  local result = {
    mode = mode,
    direct = { attempted = false, ok = false },
    clipboard = { attempted = false, ok = false },
    fallback = false,
  }

  if mode == "auto" or mode == "direct" or mode == "both" then
    result.direct.attempted = true
    result.direct.ok, result.direct.reason = direct_send(text, comments)
  end

  local should_copy = mode == "clipboard"
    or mode == "both"
    or (mode == "auto" and not result.direct.ok)
    or (mode == "direct" and not result.direct.ok and settings.fallback_to_clipboard)

  if should_copy then
    result.clipboard.attempted = true
    result.clipboard.ok, result.clipboard.reason, result.clipboard.register = clipboard_send(text)
    result.fallback = (mode == "auto" or mode == "direct") and not result.direct.ok
  end

  local success = result.direct.ok or result.clipboard.ok
  if not success then
    local reasons = {}
    if result.direct.attempted and result.direct.reason then
      reasons[#reasons + 1] = "direct: " .. result.direct.reason
    end
    if result.clipboard.attempted and result.clipboard.reason then
      reasons[#reasons + 1] = "clipboard: " .. result.clipboard.reason
    end
    result.error = table.concat(reasons, "; ")
  end
  return success, result
end

function M.modes()
  return { "auto", "direct", "clipboard", "both" }
end

return M
