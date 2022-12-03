local M = {}

local utils = require("null-ls-embedded.utils")
local methods = require("null-ls.methods")
local nl_utils = require("null-ls.utils")

M._config = {
  ignore_langs = {
    ["*"] = { "comment" }, -- ignore comment in all languages
    markdown = { "inline_markdown" }, -- ignore inline_markdown in markdown
  },
  timeout = 1000,
}

function M.config(user_config)
  vim.tbl_extend("force", M._config, user_config)
end

local function should_format(root_lang, embedded_lang, method)
  if root_lang == embedded_lang then
    if method == methods.internal.RANGE_FORMATTING then
      local available_sources = require("null-ls.generators").get_available(root_lang, method)

      available_sources = vim.tbl_filter(function(source)
        return source.opts.name ~= M.source.name
      end, available_sources)

      vim.pretty_print(available_sources)
      if #available_sources > 0 then
        return false
      end
    else
      return false
    end
  end

  local ignore_langs = M._config.ignore_langs

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

local function null_ls_fake_range_format(params, done)
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
      _nl_embedded = true,
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

function M.buf_format_injections(root_bufnr, root_ft, content, use_tmp_buf, callback)
  root_bufnr = root_bufnr or vim.api.nvim_get_current_buf()
  root_ft = root_ft or vim.api.nvim_buf_get_option(root_bufnr, "filetype")
  content = content or vim.api.nvim_buf_get_lines(root_bufnr, 0, -1, false)

  local bufnr = use_tmp_buf and utils.create_tmp_buf(content, root_ft) or root_bufnr

  local edits_per_lang = {}

  for lang, nodes in pairs(get_ts_injections(bufnr)) do
    edits_per_lang[lang] = {}
    for i, node in ipairs(nodes) do
      edits_per_lang[lang][i] = {}
      local nls_range = utils.nvim_range_to_nls({ node:range() })

      null_ls_fake_range_format({
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
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end

  local function wait_for_edits()
    local all_edits = {}

    local function is_done()
      for _, edits in pairs(edits_per_lang) do
        for _, edit in ipairs(edits) do
          if not edit.range and not edit.text then
            return false
          end
        end
      end
      return true
    end

    vim.wait(M._config.timeout, is_done, 20)

    for _, edits in pairs(edits_per_lang) do
      for _, edit in ipairs(edits) do
        if edit.range or edit.text then
          table.insert(all_edits, edit)
        end
      end
    end

    if callback then
      callback(all_edits)
    else
      vim.lsp.util.apply_text_edits(all_edits, root_bufnr, require("null-ls.client").get_offset_encoding())
    end
  end

  if callback then
    vim.schedule(wait_for_edits)
  else
    wait_for_edits()
  end
end

M.source = {
  name = "nls-embedded",
  method = { methods.internal.FORMATTING, methods.internal.RANGE_FORMATTING },
  filetypes = { "markdown", "html", "vue", "lua" },
  generator = {
    async = true,
    fn = function(params, done)
      if params._nl_embedded then
        done()
        return
      end

      if params.method == methods.internal.RANGE_FORMATTING then
        --TODO: detect ft
        local lang = "lua"

        if not should_format(params.ft, lang, params.method) then
          done()
          return
        end

        params.ft = lang

        vim.schedule(function()
          null_ls_fake_range_format(params, function(edit)
            done({ edit })
          end)
        end)
      else
        M.buf_format_injections(params.bufnr, params.ft, params.content, true, done)
      end
    end,
  },
}

function M.buf_format(bufnr)
  M.buf_format_injections(bufnr)
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

  if should_format(root_lang, node_lang) then
    local done = false
    null_ls_fake_range_format({
      bufnr = root_bufnr,
      bufname = vim.api.nvim_buf_get_name(root_bufnr),
      ft = node_lang,
      range = utils.nvim_range_to_nls(node_range),
      content = vim.api.nvim_buf_get_lines(root_bufnr, 0, -1, false),
    }, function(edit)
      vim.lsp.util.apply_text_edits({ edit }, root_bufnr, require("null-ls.client").get_offset_encoding())
      done = true
    end)

    local function wait()
      return done
    end

    vim.wait(M._config.timeout, wait, 20)
  end
end

return M
