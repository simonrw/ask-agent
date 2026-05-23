if vim.g.loaded_codex_apply == 1 then
  return
end

vim.g.loaded_codex_apply = 1

require("codex_apply").setup()
