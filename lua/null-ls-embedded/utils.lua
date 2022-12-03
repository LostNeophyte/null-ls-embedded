local M = {}

function M.nls_range_to_nvim(range)
  return { range.row - 1, range.col - 1, range.end_row - 1, range.end_col - 1 }
end

function M.nvim_range_to_nls(range)
  return { row = range[1] + 1, col = range[2] + 1, end_row = range[3] + 1, end_col = range[4] + 1 }
end

function M.create_tmp_buf(lines, ft)
  local tmp_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(tmp_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(tmp_bufnr, "filetype", ft)
  return tmp_bufnr
end

---Creates a temp buffer with prepared content
---@param opts {root_bufnr: number, ft: string, content: string[], range: number[]}
---@return number|nil tmp_bufnr or nil if the range is empty
---@return table|nil buf_to_text_opts
function M.prepare_tmp_buffer(opts)
  local api = vim.api

  local range = opts.range

  local tmp_bufnr = M.create_tmp_buf(opts.content, opts.ft)

  -- set options
  local options = { "shiftwidth", "tabstop", "expandtab", "eol", "fixeol", "fileformat" }
  for _, option in pairs(options) do
    api.nvim_buf_set_option(tmp_bufnr, option, api.nvim_buf_get_option(opts.root_bufnr, option))
  end

  -- get lines from the range
  local range_lines = vim.api.nvim_buf_get_text(tmp_bufnr, range[1], range[2], range[3], range[4], {})

  local indent = vim.api.nvim_buf_get_text(tmp_bufnr, range[1], 0, range[1], range[2], {})[1]
  indent = indent:match("^[ \t]*") or ""

  -- remove indentation
  if indent ~= "" then
    for i, line in ipairs(range_lines) do
      range_lines[i] = line:gsub("^" .. indent, "")
    end
  end

  local trimmed_front = false
  local trimmed_back = false

  -- trim front empty lines
  while range_lines[1]:match("^[ \t]*$") do
    table.remove(range_lines, 1)
    trimmed_front = true
    if not range_lines[1] then
      return
    end
  end

  -- trim back empty lines
  while range_lines[#range_lines]:match("^[ \t]*$") do
    table.remove(range_lines, #range_lines)
    trimmed_back = true
    if not range_lines[#range_lines] then
      return
    end
  end

  -- for i = #range_lines, 1, -1 do
  --   if range_lines[i]:match("^[ \t]*") then
  --     table.remove(range_lines, i)
  --   else
  --     break
  --   end
  -- end

  api.nvim_buf_set_lines(tmp_bufnr, 0, -1, false, range_lines)

  return tmp_bufnr, {
    indent = indent,
    trimmed_front = trimmed_front,
    trimmed_back = trimmed_back,
  }
end

---Trims last line whitespace form the range
---@param range table null-ls range (modified in place)
---@param lines string[]
---@return number[] range nvim range
function M.trim_range(range, lines)
  if range.row ~= range.end_row then
    local last_text = lines[range.end_row]:sub(1, range.end_col - 1)
    if last_text:match("^[ \t]*$") then
      local row = range.end_row - 1
      range.end_row = row
      range.end_col = #lines[row] + 1 -- past the end
    end
  end
  return M.nls_range_to_nvim(range)
end

---Extracts formattted text from buffer
---@param bufnr number
---@param opts table
---@return string text
function M.buf_to_text(bufnr, opts)
  local nl_utils = require("null-ls.utils")
  local line_ending = nl_utils.get_line_ending(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local text = ""
  -- if opts.trimmed_front then
  --   text = text .. line_ending
  -- end

  text = text .. lines[1]

  if #lines > 1 then
    text = text .. line_ending
  end

  for i = 2, #lines - 1 do
    text = text .. opts.indent .. lines[i] .. line_ending
  end

  text = text .. opts.indent .. lines[#lines]

  if opts.trimmed_back then
    text = text .. line_ending
  end

  return text
end

return M
