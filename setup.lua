vim.cmd([[set rtp+=.]])

require("ask-agent").setup()

ask_agent_statusline = function()
    return require("ask-agent").statusline()
end

vim.o.statusline = vim.o.statusline .. " %{v:lua.ask_agent_statusline()}"
