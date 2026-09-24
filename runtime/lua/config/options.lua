-- Loaded by LazyVim before plugins. nvs.ide state (stage, local AI) is read
-- here so plugin specs such as the Ollama completion one can depend on it.
require("nvs.state").load()

vim.opt.relativenumber = true
vim.opt.scrolloff = 8
vim.opt.mouse = "a"

if vim.g.neovide then
  vim.o.guifont = "BigBlueTerm437 Nerd Font Mono:h13"
  vim.g.neovide_cursor_animation_length = 0.08
end
