# null-ls-embedded

Plugin for formatting embedded code using [null-ls](https://github.com/jose-elias-alvarez/null-ls.nvim) in NeoVim.
Embedded languages are found using `injections.csm` treesitter queries from [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter),
so if the highlighting works, the formatting should as well.

https://user-images.githubusercontent.com/110467150/205292765-e2f89639-f0aa-4ca0-af71-fc69478ff6d7.mp4

# Disclaimer

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

- `require("null-ls-embedded").buf_format()` - format every code block in the buffer
- `require("null-ls-embedded").format_current()` - format the current code block

## Configuration

### Additional queries

If you want the plugin to detect additional code blocks, add the treesitter injections to `injections.csm`,
you'll also get syntax highlighting as a side effect :)

### Stop some embedded languages from being formatted

To stop some languages from being formatted, you can edit the `ignore_langs` table

defaults:

```lua
require("null-ls-embedded").config.ignore_langs = {
  ["*"] = { "comment" }, -- don't format `comment` in all languages
  markdown = { "inline_markdown" }, -- don't format embedded `inline_markdown` in `markdown` files
}
```

## Credits

- **TJ DeVries**: [Magically format embedded languages in Neovim](https://www.youtube.com/watch?v=v3o9YaHBM4Q)
- **NeoVim**: [Code for getting treesitter injections](https://github.com/neovim/neovim/blob/86f9e29c86af9a7f6eb30a7d8ff529898a8b20ec/runtime/lua/vim/treesitter/languagetree.lua#L337)
