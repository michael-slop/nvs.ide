-- Run inside Neovim by the shell right after nvim_get_api_info, before nvim_ui_attach.
-- Arguments: the shell's channel id, and whether the window serves the clipboard.
local channel, serve_clipboard = ...

vim.g.nvs_channel = channel
vim.g.nvs_shell = true

-- GUI basics (same as Neovide's init.lua).
vim.o.lazyredraw = false
vim.o.termguicolors = true

-- The house font as the default. This runs before the user's config, which may still
-- override 'guifont'. Without it Neovim's own default (Cascadia/Consolas) would win.
-- :h9 is 12 px at 96 dpi, the size the pixel font is drawn for.
vim.o.guifont = "BigBlueTerm437 Nerd Font Mono:h9,Cascadia Mono:h9,Consolas:h9,DejaVu Sans Mono:h9,Liberation Mono:h9,Noto Sans Mono:h9,Courier New:h9"

-- The clipboard, on Linux: the window serves + and * itself (shell/src/clipboard.rs), so
-- copy and paste work without wl-copy, xclip or xsel installed. This runs before the
-- user's config, where setting g:clipboard replaces it. As in Neovide's init.lua.
if serve_clipboard then
  local function copy(register)
    return function(lines)
      vim.rpcrequest(channel, "nvs.set_clipboard", lines, register)
    end
  end
  local function paste(register)
    return function()
      return vim.rpcrequest(channel, "nvs.get_clipboard", register)
    end
  end
  vim.g.clipboard = {
    name = "nvs-ide",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = false,
  }
end

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
