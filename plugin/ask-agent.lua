if vim.g.loaded_ask_agent == 1 then
  return
end

vim.g.loaded_ask_agent = 1

require("ask-agent").setup()
