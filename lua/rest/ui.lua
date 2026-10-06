local fmt = require("rest.format")

local M = {}

M._buf = nil
M._ns = nil

local function status_hl(status)
  if status >= 500 then
    return "RestStatusCodeServerError"
  elseif status >= 400 then
    return "RestStatusCodeError"
  elseif status >= 300 then
    return "RestStatusCodeRedirect"
  elseif status >= 200 then
    return "RestStatusCodeSuccess"
  end
  return "RestStatusCodeInformation"
end

local HL_GROUPS = {
  RestStatusCodeInformation = { fg = "#ffffff", default = true },
  RestStatusCodeSuccess = { fg = "#00d700", default = true },
  RestStatusCodeRedirect = { fg = "#ffaf00", default = true },
  RestStatusCodeError = { fg = "#ff0000", default = true },
  RestStatusCodeServerError = { fg = "#000000", bg = "#ff0000", default = true },
  RestHeadingsAttributes = { link = "@function.method", default = true },
  RestHeadingsValues = { link = "Comment", default = true },
}

local function define_highlights()
  for name, spec in pairs(HL_GROUPS) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("RestNvimHighlights", { clear = true }),
  callback = define_highlights,
})

local function body_lines(result, opts)
  local jq_path = opts.jq_path
  if jq_path == "auto" then
    jq_path = nil
  end
  local pretty, _ = fmt.pretty(result.body, {
    jq_path = jq_path,
    decode = vim.json.decode,
  })
  local text = pretty or result.body
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

local function status_line(result)
  return ("HTTP/%s %d %s"):format(result.version, result.status, result.reason)
end

local function response_lines(result, opts)
  local lines = { status_line(result) }
  for _, header in ipairs(result.headers) do
    lines[#lines + 1] = header.name .. ": " .. header.value
  end
  lines[#lines + 1] = ""
  for _, line in ipairs(body_lines(result, opts)) do
    lines[#lines + 1] = line
  end
  return lines
end

local function find_window(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

local function content_type(headers)
  for _, header in ipairs(headers or {}) do
    if header.name:lower() == "content-type" then
      return header.value
    end
  end
end

---Set the buffer filetype and make sure treesitter highlights the result body.
local function apply_language(buf, ft)
  pcall(vim.treesitter.stop, buf)
  vim.bo[buf].filetype = ft or ""
  if ft and not vim.treesitter.highlighter.active[buf] then
    pcall(vim.treesitter.start, buf, ft)
  end
end

---Overlay status + header lines so treesitter noise cannot leak into them.
---Priority `user` (200) beats treesitter (100) and semantic tokens (125).
local function overlay(buf, result)
  vim.api.nvim_buf_clear_namespace(buf, M._ns, 0, -1)
  local prio = vim.hl.priorities.user

  local line = status_line(result)
  local code = tostring(result.status)
  local code_col = #"HTTP/" + #tostring(result.version) + 1
  if line:sub(code_col + 1, code_col + #code) == code then
    vim.api.nvim_buf_set_extmark(buf, M._ns, 0, 0, {
      hl_group = "Normal",
      end_col = code_col,
      priority = prio,
    })
    vim.api.nvim_buf_set_extmark(buf, M._ns, 0, code_col, {
      hl_group = status_hl(result.status),
      end_col = code_col + #code,
      priority = prio,
    })
    vim.api.nvim_buf_set_extmark(buf, M._ns, 0, code_col + #code, {
      hl_group = "Normal",
      hl_eol = true,
      priority = prio,
    })
  else
    vim.api.nvim_buf_set_extmark(buf, M._ns, 0, 0, {
      hl_group = status_hl(result.status),
      hl_eol = true,
      priority = prio,
    })
  end

  for i, header in ipairs(result.headers) do
    local colon = #header.name
    vim.api.nvim_buf_set_extmark(buf, M._ns, i, 0, {
      hl_group = "RestHeadingsAttributes",
      end_col = colon,
      priority = prio,
    })
    vim.api.nvim_buf_set_extmark(buf, M._ns, i, colon + 1, {
      hl_group = "RestHeadingsValues",
      end_col = colon + 2 + #header.value,
      priority = prio,
    })
  end
end

local function apply(buf, result, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ft = fmt.detect_ft(content_type(result.headers), result.body)
  apply_language(buf, ft)
  overlay(buf, result)
end

---Open (or update) the response window.
function M.open(result, opts)
  opts = opts or {}
  M._ns = M._ns or vim.api.nvim_create_namespace("rest.nvim")
  local lines = response_lines(result, opts)

  local win
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    apply(M._buf, result, lines)
    win = find_window(M._buf)
    if not win then
      vim.cmd(opts.split == "horizontal" and "botright split" or "botright vsplit")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, M._buf)
    end
  else
    M._buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, M._buf, "rest://response")
    vim.bo[M._buf].buftype = "nofile"
    vim.bo[M._buf].bufhidden = "hide"
    vim.bo[M._buf].swapfile = false
    apply(M._buf, result, lines)
    vim.cmd(opts.split == "horizontal" and "botright split" or "botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, M._buf)
  end

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  return win
end

return M
