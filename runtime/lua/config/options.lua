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

-- Inside the nvs.ide shell the window draws the tab strip and the status bar itself,
-- so Neovim's own tabline and statusline stay out of the grid.
if vim.g.nvs_shell then
  vim.opt.showtabline = 0
  vim.opt.laststatus = 0
end

-- Settings chosen on the Settings screen (lua/nvs/prefs.lua writes lua/nvs/settings.lua).
-- Loaded last so they win over the defaults above; plugin-level ones land in
-- vim.g.nvs_settings for lua/plugins/nvs.lua.
vim.g.nvs_settings = vim.g.nvs_settings or {}
pcall(require, "nvs.settings")
