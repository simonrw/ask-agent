# codex-apply.nvim

Select code in visual mode, write an instruction in a floating prompt, and let
the Codex CLI implement the change in place.

The plugin uses Codex non-interactive mode:

```sh
codex exec --sandbox workspace-write --cd <repo-root> -
```

Codex reads the generated prompt from stdin. The selected text is included as
focus context, and Codex may edit related files in the Git repository.

## Requirements

- Neovim 0.10 or newer
- `codex` CLI available on `$PATH`
- A Git repository

## Installation

With `lazy.nvim`:

```lua
{
  "your-name/codex-apply.nvim",
  config = function()
    require("codex_apply").setup()
  end,
}
```

For local development:

```lua
{
  dir = "/home/simon/dev/ask-agent",
  config = function()
    require("codex_apply").setup()
  end,
}
```

## Usage

Select a block in visual mode and run:

```vim
:CodexApplySelection
```

Recommended mapping:

```lua
vim.keymap.set("v", "<leader>ca", ":CodexApplySelection<CR>", {
  desc = "Ask Codex to change selection",
})
```

Prompt window keys:

- `<CR>` submits
- `<S-CR>` inserts a new line
- `<C-j>` also inserts a new line for terminals that do not send Shift-Enter
- `<Esc>` cancels

## Configuration

```lua
require("codex_apply").setup({
  codex_cmd = "codex",
  sandbox = "workspace-write",
  model = nil,
  extra_args = {},
  notify = vim.notify,
  prompt_width = 72,
  prompt_height = 10,
})
```

The plugin refuses to run outside a Git repository, matching Codex's default
safety model.
