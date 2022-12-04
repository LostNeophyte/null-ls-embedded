local M = {}

local config = require("null-ls-embedded.config")

local utils = require("null-ls-embedded.utils")
local methods = require("null-ls.methods")
local nl_utils = require("null-ls.utils")

local function nls_get_range_edit_async(params, done)
  local lsp = vim.lsp

  local root_bufnr = params.bufnr
  local range = utils.trim_range(params.range, params.content)

  local tmp_bufnr, buf_to_text_opts = utils.prepare_tmp_buffer({
    root_bufnr = root_bufnr,
    ft = params.ft,
    content = params.content,
    range = range,
  })

  if not tmp_bufnr or not buf_to_text_opts then
    done()
    return
  end

  local content_before_format = nl_utils.buf.content(tmp_bufnr)
  local function handle_err(err)
    require("null-ls.logger"):warn("[null-ls-embedded] " .. err)
    vim.api.nvim_buf_delete(tmp_bufnr, { force = true })
    done()
  end

  local function make_params()
    return {
      _nls_embedded = true,
      lsp_method = methods.lsp.FORMATTING,
      method = methods.internal.FORMATTING,
      bufnr = tmp_bufnr,
      bufname = params.bufname:gsub("%.[^%.]+$", "." .. params.ft),
      content = nl_utils.buf.content(tmp_bufnr),
      ft = params.ft,
    }
  end

  local function postprocess(edit, parameters)
    edit.range = {
      ["start"] = {
        line = 0,
        character = 0,
      },
      ["end"] = {
        line = #parameters.content,
        character = 0,
      },
    }
    edit.newText = edit.text:gsub("[\r\n]$", "")
  end

  local function after_each(edits)
    local ok, err = pcall(lsp.util.apply_text_edits, edits, tmp_bufnr, require("null-ls.client").get_offset_encoding())
    if not ok then
      handle_err(err)
    end
  end

  local function callback()
    local diff = nil
    local function cleanup()
      done(diff)
      vim.api.nvim_buf_delete(tmp_bufnr, { force = true })
    end
    local content_after_format = nl_utils.buf.content(tmp_bufnr)
    local ok, err = pcall(function()
      -- don't format invalid regions with range formatting
      if params.method == methods.internal.RANGE_FORMATTING then
        local same = true

        if #content_before_format == #content_after_format then
          for i = 1, #content_before_format do
            if content_before_format[i] ~= content_after_format[i] then
              same = false
              break
            end
          end
        end

        if same then
          return
        end
      end

      local text = utils.buf_to_text(tmp_bufnr, buf_to_text_opts)

      diff = {
        text = text,
        newText = text,
        row = params.range.row,
        col = params.range.col,
        end_row = params.range.end_row,
        end_col = params.range.end_col,
      }
      diff.range = nl_utils.range.to_lsp(diff)
    end)

    if not ok then
      handle_err(err)
    else
      cleanup()
    end
  end

  require("null-ls.generators").run_registered_sequentially({
    filetype = params.ft,
    method = methods.internal.FORMATTING,
    make_params = make_params,
    postprocess = postprocess,
    after_each = after_each,
    callback = callback,
  })
end

---@return any
local function nls_get_range_edit(params)
  local ret = false

  nls_get_range_edit_async(params, function(ret_)
    ret = ret_
  end)

  local function is_done()
    return ret ~= false
  end

  vim.wait(config.timeout, is_done, 20)

  return ret
end

local function nls_get_buf_edits(root_bufnr, root_ft, content, use_tmp_buf)
  root_bufnr = root_bufnr or vim.api.nvim_get_current_buf()
  root_ft = root_ft or vim.api.nvim_buf_get_option(root_bufnr, "filetype")
  content = content or vim.api.nvim_buf_get_lines(root_bufnr, 0, -1, false)

  local ts_bufnr = use_tmp_buf and utils.create_tmp_buf(content, root_ft) or root_bufnr

  local edits_per_lang = {}

  for lang, nodes in pairs(utils.get_ts_injection_nodes(ts_bufnr)) do
    edits_per_lang[lang] = {}
    for i, node in ipairs(nodes) do
      edits_per_lang[lang][i] = false
      local nls_range = utils.nvim_range_to_nls({ node:range() })

      nls_get_range_edit_async({
        bufnr = root_bufnr,
        bufname = vim.api.nvim_buf_get_name(root_bufnr),
        ft = lang,
        range = nls_range,
        content = content,
      }, function(edit)
        edits_per_lang[lang][i] = edit
      end)
    end
  end

  if use_tmp_buf then
    vim.api.nvim_buf_delete(ts_bufnr, { force = true })
  end

  local function is_done()
    for _, edits in pairs(edits_per_lang) do
      for _, edit in ipairs(edits) do
        if not edit then
          return false
        end
      end
    end
    return true
  end

  while true do
    if is_done() then
      break
    else
      vim.wait(20)
    end
  end

  local all_edits = {}

  for _, edits in pairs(edits_per_lang) do
    for _, edit in ipairs(edits) do
      if edit then
        table.insert(all_edits, edit)
      end
    end
  end

  return all_edits
end

M.nls_source = {
  name = "nls-embedded",
  method = { methods.internal.FORMATTING, methods.internal.RANGE_FORMATTING },
  filetypes = { "markdown", "html", "vue", "lua" },
  generator = {
    async = false,
    fn = function(params)
      if params._nls_embedded then
        return
      end

      if params.method == methods.internal.RANGE_FORMATTING then
        local parser = vim.treesitter.get_parser()
        local range = utils.nls_range_to_nvim(params.range)
        local lang = parser:language_for_range(range):lang()

        if not utils.should_format(params.ft, lang, params.method) then
          return
        end

        params.ft = lang

        return { nls_get_range_edit(params) }
      else
        return nls_get_buf_edits(params.bufnr, params.ft, params.content, true)
      end
    end,
  },
  with = function(user_opts)
    local ret = vim.tbl_extend("force", M.nls_source, user_opts)
    M.nls_source.name = ret.name
    return ret
  end,
}

M.config = config

function M.buf_format(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local edits = nls_get_buf_edits(bufnr)
  vim.lsp.util.apply_text_edits(edits, bufnr, require("null-ls.client").get_offset_encoding())
end

function M.format_current()
  local root_bufnr = vim.api.nvim_get_current_buf()
  local root_lang = vim.api.nvim_buf_get_option(root_bufnr, "filetype")

  local parser = vim.treesitter.get_parser()
  local node = require("nvim-treesitter.ts_utils").get_node_at_cursor(0, true)
  local node_range = { node:range() }
  local node_lang = parser:language_for_range(node_range):lang()

  if root_lang == node_lang then
    for i = 0, node:named_child_count() - 1 do
      local child = node:named_child(i)
      local child_range = { child:range() }
      local child_lang = parser:language_for_range(child_range):lang()
      if child_lang ~= node_lang then
        node = child
        node_range = child_range
        node_lang = child_lang
        break
      end
    end
  end

  if utils.should_format(root_lang, node_lang) then
    local edit = nls_get_range_edit({
      bufnr = root_bufnr,
      bufname = vim.api.nvim_buf_get_name(root_bufnr),
      ft = node_lang,
      range = utils.nvim_range_to_nls(node_range),
      content = vim.api.nvim_buf_get_lines(root_bufnr, 0, -1, false),
    })

    vim.lsp.util.apply_text_edits({ edit }, root_bufnr, require("null-ls.client").get_offset_encoding())
  end
end

return M
