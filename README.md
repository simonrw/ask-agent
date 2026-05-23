# codex-apply.nvim

Select code in visual mode, write an instruction in a floating prompt, and let
the Codex CLI implement the change in place.

The plugin uses Codex non-interactive mode:

```sh
codex exec --sandbox workspace-write --cd <repo-root> -
```

Codex reads the generated prompt from stdin. The selected text is included as
focus context, and Codex may edit related files in the Git repository.
While Codex runs, progress streams into a bottom split and Neovim checks for
file changes so edited buffers can refresh during the run.

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

Progress window keys:

- `q` closes the progress split

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
  progress_height_ratio = 0.33,
  close_progress_on_success = false,
  live_reload = true,
  live_reload_interval_ms = 1000,
})
```

Live reload uses `:checktime`, so Neovim can update buffers as soon as Codex
writes files. This works best with unmodified buffers; the plugin saves the
current buffer before launching Codex.

The plugin refuses to run outside a Git repository, matching Codex's default
safety model.
