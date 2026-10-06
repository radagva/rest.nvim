local fmt = require("rest.format")

local M = {}

M._buf = nil
M._ns = nil

local function status_hl(status)
  if status >= 200 and status < 300 then
    return "MoreMsg"
  elseif status >= 300 and status < 400 then
    return "WarningMsg"
  elseif status >= 400 then
    return "ErrorMsg"
  end
  return "Comment"
end

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

local function response_lines(result, opts)
  local lines = {
    ("HTTP/%s %d %s"):format(result.version, result.status, result.reason),
  }
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
  vim.api.nvim_buf_set_extmark(buf, M._ns, 0, 0, {
    hl_group = status_hl(result.status),
    hl_eol = true,
    priority = prio,
  })
  for i = 1, #result.headers do
    vim.api.nvim_buf_set_extmark(buf, M._ns, i, 0, {
      hl_group = "Comment",
      hl_eol = true,
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
