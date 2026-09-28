-- Run inside the window by CI on Linux:
--   nvs-ide --send ':luafile tests/clipboard_probe.lua<CR>' --screenshot shot.png
-- Writes key=value lines to $NVS_PROBE_OUT: which provider Neovim chose (the window's is
-- "nvs-ide", shell/src/clipboard.rs), a copy read back through it, and on X11, whether
-- another program (xclip) sees what the window copied and the window sees what xclip copied.
local out = {}
local function add(key, value)
  out[#out + 1] = key .. "=" .. vim.trim(tostring(value))
end

-- A refused copy raises (Wayland refuses one without a seat event, as under a headless
-- compositor); record it and keep going, so the file is always written.
local function try(key, fn)
  local ok, value = pcall(fn)
  add(ok and key or (key .. "_error"), ok and value or tostring(value):gsub("\n", " "))
end

add("provider", vim.fn["provider#clipboard#Executable"]())
try("roundtrip", function()
  vim.fn.setreg("+", "nvs clipboard round trip")
  return vim.fn.getreg("+")
end)

local x11 = (vim.env.WAYLAND_DISPLAY or "") == "" and (vim.env.DISPLAY or "") ~= ""
if x11 and vim.fn.executable("xclip") == 1 then
  add("xclip_sees", vim.fn.system({ "xclip", "-o", "-selection", "clipboard" }))
  -- xclip -i stays behind to own the selection; with its output on our pipe, system()
  -- would wait for it forever.
  vim.fn.system({ "sh", "-c", "printf 'copied by xclip' | xclip -i -selection clipboard >/dev/null 2>&1" })
  add("window_sees", vim.fn.getreg("+"))
end

vim.fn.writefile(out, vim.env.NVS_PROBE_OUT or "clipboard-probe.txt")
