local M = {}

M.config = {
  ignore_langs = {
    ["*"] = { "comment" }, -- ignore comment in all languages
    markdown = { "inline_markdown" }, -- ignore inline_markdown in markdown
  },
}

local function should_format(root_lang, embedded_lang)
  local ignore_langs = M.config.ignore_langs
  if vim.tbl_contains(ignore_langs["*"], embedded_lang) then
    return false
  end

  if ignore_langs[root_lang] then
    return not vim.tbl_contains(ignore_langs[root_lang], embedded_lang)
  end

  return true
end

-- modified code from <neovim/runtime/lua/vim/treesitter/languagetree.lua>
local function get_ts_injections(bufnr)
  local root_lang = vim.api.nvim_buf_get_option(bufnr, "filetype")
  local query = require("nvim-treesitter.query").get_query(root_lang, "injections")

  local root = vim.treesitter.get_parser():parse()[1]:root()

  local injections = {}

  for _, match, metadata in query:iter_matches(root, bufnr, 0, -1) do
    local nodes = {}
    local lang
    if metadata.language then
      lang = metadata.language
    end

    for id, node in pairs(match) do
      local name = query.captures[id]

      if name == "language" and not lang then
        lang = vim.treesitter.query.get_node_text(node, bufnr)
      elseif name == "content" and #nodes == 0 then
        table.insert(nodes, node)
      elseif string.sub(name, 1, 1) ~= "_" then
        lang = lang or name

        table.insert(nodes, node)
      end
    end

    if should_format(root_lang, lang) then
      if not injections[lang] then
        injections[lang] = {}
      end
      vim.list_extend(injections[lang], nodes)
    end
  end

  return injections
end

---Format embedded code using null-ls
---@param bufnr number 0 for current
---@param lang string programming language of the code to format
---@param range number[] list with 4 values: {tart_row, start_col, end_row, end_col}
local function null_ls_embedded_format(bufnr, lang, range, callback_override)
  local methods = require("null-ls.methods")
  local u = require("null-ls.utils")
  local api = vim.api
  local lsp = vim.lsp

  local temp_bufnr = api.nvim_create_buf(false, true)

  local options = { "eol", "fixeol", "fileformat" }
  for _, option in pairs(options) do
    api.nvim_buf_set_option(temp_bufnr, option, api.nvim_buf_get_option(bufnr, option))
  end
  api.nvim_buf_set_option(temp_bufnr, "filetype", lang)
  local old_lines = vim.api.nvim_buf_get_text(bufnr, range[1], range[2], range[3], range[4], {})
  api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, old_lines)

  local handle_err = function(err)
    require("null-ls.logger"):warn("[null-ls-embedded] Formatting error: " .. err)
    api.nvim_buf_delete(temp_bufnr, { force = true })
  end

  local make_params = function()
    local params = u.make_params({ filetype = lang }, methods.internal.FORMATTING)
    -- override actual content w/ temp buffer content
    params.content = u.buf.content(temp_bufnr)
    return params
  end

  local after_each = function(edits)
    local ok, err = pcall(lsp.util.apply_text_edits, edits, temp_bufnr, require("null-ls.client").get_offset_encoding())
    if not ok then
      handle_err(err)
    end
  end

  local callback = function()
    local ok, err = pcall(function()
      local new_lines = api.nvim_buf_get_lines(temp_bufnr, 0, -1, false)

      local function lines_to_text(lines, line_ending, indent)
        local result = lines[1] .. line_ending
        for index = 2, #lines do
          result = result .. indent .. lines[index] .. line_ending
        end
        return result:gsub("[\r\n]+$", "")
      end

      local indent = vim.api.nvim_buf_get_text(bufnr, range[1], 0, range[1], range[2], {})[1] or ""

      local diff = {
        newText = lines_to_text(new_lines, u.get_line_ending(bufnr), indent),
        range = {
          start = { line = range[1], character = range[2] },
          ["end"] = { line = range[3], character = range[4] },
        },
      }

      if old_lines[#old_lines]:match("^[ \t]*$") then
        diff.newText = diff.newText .. u.get_line_ending(bufnr) .. old_lines[#old_lines]
      end

      if callback_override then
        callback_override(diff)
      else
        vim.lsp.util.apply_text_edits({ diff }, bufnr, require("null-ls.client").get_offset_encoding())
      end

      api.nvim_buf_delete(temp_bufnr, { force = true })
    end)

    if not ok then
      handle_err(err)
    end
  end

  local postprocess = function(edit, params)
    edit.range = {
      ["start"] = {
        line = 0,
        character = 0,
      },
      ["end"] = {
        line = #params.content,
        character = 0,
      },
    }
    -- strip trailing newline
    edit.newText = edit.text:gsub("[\r\n]$", "")
  end

  require("null-ls.generators").run_registered_sequentially({
    filetype = lang,
    method = methods.internal.FORMATTING,
    make_params = make_params,
    postprocess = postprocess,
    after_each = after_each,
    callback = callback,
  })
end

---Format every code block in the buffer
---@param bufnr number|nil Number of the buffer or nil for the current one
function M.buf_format(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local edits_per_lang = {}

  for lang, nodes in pairs(get_ts_injections(bufnr)) do
    edits_per_lang[lang] = {}
    for i, node in ipairs(nodes) do
      edits_per_lang[lang][i] = {}

      null_ls_embedded_format(bufnr, lang, { node:range() }, function(edit)
        edits_per_lang[lang][i] = edit
      end)
    end
  end

  local function is_done()
    for _, edits in pairs(edits_per_lang) do
      for _, edit in ipairs(edits) do
        if not edit.range then
          return false
        end
      end
    end
    return true
  end

  vim.wait(500, is_done, 50)

  local edits_to_apply = {}

  for _, edits in pairs(edits_per_lang) do
    for _, edit in ipairs(edits) do
      if edit.range then
        table.insert(edits_to_apply, edit)
      end
    end
  end

  vim.lsp.util.apply_text_edits(edits_to_apply, bufnr, require("null-ls.client").get_offset_encoding())
end

---Format current code block
function M.format_current()
  local root_lang = vim.api.nvim_buf_get_option(0, "filetype")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_range = { cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2] }

  local parser = vim.treesitter.get_parser()
  local embedded_lang = parser:language_for_range(cursor_range):lang()
  local node = require("nvim-treesitter.ts_utils").get_node_at_cursor(0, true)
  local range = { node:range() }

  if should_format(root_lang, embedded_lang) then
    null_ls_embedded_format(0, embedded_lang, range)
  end
end

return M
