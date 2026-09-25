-- Run inside Neovim by the shell right after nvim_get_api_info, before nvim_ui_attach.
-- Argument: the shell's channel id.
local channel = ...

vim.g.nvs_channel = channel
vim.g.nvs_shell = true

-- GUI basics (same as Neovide's init.lua).
vim.o.lazyredraw = false
vim.o.termguicolors = true

-- The house font as the default. This runs before the user's config, which may still
-- override 'guifont'. Without it Neovim's own default (Cascadia/Consolas) would win.
-- :h9 is 12 px at 96 dpi, the size the pixel font is drawn for.
vim.o.guifont = "BigBlueTerm437 Nerd Font Mono:h9,Cascadia Mono:h9,Consolas:h9,Courier New:h9"

-- A default window title unless the user set one.
local title_info = vim.api.nvim_get_option_info2("title", {})
local titlestring_info = vim.api.nvim_get_option_info2("titlestring", {})
if not (title_info.was_set or titlestring_info.was_set) then
  vim.o.title = true
  vim.o.titlestring = "%F"
end

-- Tell the shell the exit code before the channel closes.
vim.api.nvim_create_autocmd("VimLeavePre", {
  pattern = "*",
  once = true,
  nested = true,
  callback = function()
    pcall(vim.rpcrequest, channel, "nvs.quit", vim.v.exiting or 0)
  end,
})
