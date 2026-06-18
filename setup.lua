vim.cmd([[set rtp+=.]])

require("codex_apply").setup()

codex_apply_statusline = function()
    return require("codex_apply").statusline()
end

vim.o.statusline = vim.o.statusline .. " %{v:lua.codex_apply_statusline()}"
