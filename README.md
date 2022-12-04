# null-ls-embedded

Plugin for formatting embedded code using [null-ls](https://github.com/jose-elias-alvarez/null-ls.nvim) in NeoVim.
Embedded languages are found using `injections.csm` treesitter queries from [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter),
so if the highlighting works, the formatting should as well.

https://user-images.githubusercontent.com/110467150/205495468-f0f8b9d7-5730-48d6-beb1-ea60dabb0021.mp4

## Disclaimer

Currently the plugin works correctly with formatters that don't need an actual file,
correct functioning with other formatters is not guaranteed (some work, some don't). see https://github.com/LostNeophyte/null-ls-embedded/issues/3

## installation

### Dependencies:

- [null-ls](https://github.com/jose-elias-alvarez/null-ls.nvim)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)

packer:

```lua
use({ "LostNeophyte/null-ls-embedded" })
```

## Formatting

Add this plugin to the null-ls sources or use the builtin functions.

### As a null-ls source

To get the best results add it as the last one.

```lua
require("null-ls").setup({
  sources = {
    -- other sources
    require("null-ls-embedded").nls_source,
  },
})
```

Format by calling `vim.lsp.buf.format`.
Range formatting is supported with this method (as long as the formatter will format the selected range).


### By calling functions

- `require("null-ls-embedded").buf_format()` - format every code block in the buffer
- `require("null-ls-embedded").format_current()` - format the current code block

## Configuration

```lua
local config = {
  ignore_langs = {
    ["*"] = { "comment" }, -- ignore `comment` in all languages
    markdown = { "markdown_inline" }, -- ignore `markdown_inline` in `markdown`
  },
  timeout = 1000,
}
require("null-ls-embedded").config(config)
```

### Additional queries

If you want the plugin to detect additional code blocks, add the treesitter queries to `injections.csm`.

## Credits

- **TJ DeVries**: [Magically format embedded languages in Neovim](https://www.youtube.com/watch?v=v3o9YaHBM4Q)
- **NeoVim**: [Code for getting treesitter injections](https://github.com/neovim/neovim/blob/86f9e29c86af9a7f6eb30a7d8ff529898a8b20ec/runtime/lua/vim/treesitter/languagetree.lua#L337)
