local config = {
  ignore_langs = {
    ["*"] = { "comment" }, -- ignore comment in all languages
    markdown = { "markdown_inline" }, -- ignore markdown_inline in markdown
  },
  timeout = 1000,
}

return setmetatable({}, {
  __index = function(_, key)
    return config[key]
  end,
  __call = function(_, user_config)
    config = vim.tbl_extend("force", config, user_config)
  end,
})
