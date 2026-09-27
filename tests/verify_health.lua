-- Headless check of the :checkhealth nvs provider (runtime/lua/nvs/health.lua). Run it in a
-- sandbox, never against your own profile: tests/run.ps1 shows the XDG_* and NVIM_APPNAME
-- environment. From the repo root, with that environment set:
--   nvim --headless -c 'luafile tests/verify_health.lua'
-- It also runs with no plugins at all, which is what CI does:
--   nvim --clean --headless --cmd 'set rtp^=runtime' -c 'luafile tests/verify_health.lua'
-- Every line printed starts with PASS or FAIL; the exit code is the number of FAILs.
local out, fails = {}, 0
local function check(name, ok, detail)
  if not ok then
    fails = fails + 1
  end
  table.insert(out, (ok and "PASS " or "FAIL ") .. "health: " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
end
local function finish()
  io.write(table.concat(out, "\n") .. "\n")
  io.flush()
  os.exit(fails)
end
-- A prompt left open would hang a headless Neovim forever; give up after a minute.
vim.defer_fn(function()
  check("watchdog", false, "60 s passed")
  finish()
end, 60000)

-- lazy.nvim's VeryLazy never fires headless; the runtime registers its commands there.
pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "VeryLazy", modeline = false })

local ok, err = pcall(vim.cmd, "checkhealth nvs")
check("checkhealth nvs runs", ok, err)
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
local bufname = vim.api.nvim_buf_get_name(0)
check("report buffer is the health window", vim.bo.filetype == "checkhealth" and bufname:find("health://", 1, true) ~= nil, vim.bo.filetype .. " " .. bufname)
check("provider was found", text:find("nvs:", 1, true) ~= nil, text:sub(1, 160))
check("provider raised no exception", not text:find("Failed to run healthcheck", 1, true), text:match("Exception:[^\n]*\n[^\n]*"))
check("report is not empty", not text:find("plugin is empty", 1, true))
check("Neovim version reported", text:find("Neovim %d+%.%d+%.%d+") ~= nil)
-- Every tool is either found (with its path) or reported missing; both mention it by label.
for _, label in ipairs({ "git", "rg (ripgrep)", "fd", "tree-sitter", "C compiler", "curl", "node", "llama-server" }) do
  local mentioned = text:find(label .. ": ", 1, true) ~= nil or text:find(label .. " not found", 1, true) ~= nil
  check("mentions " .. label, mentioned)
end
-- The version shown next to a tool is its version line, not the first thing it printed:
-- llama-server logs "... llama_server: initializing ..." before "version: ...".
local ok_health, health = pcall(require, "nvs.health")
check("health module loads", ok_health, health)
if ok_health then
  local llama = "0.00.000.682 I srv  llama_server: initializing ...\nversion: 0.5.0-dev (build 11149, commit d2e54583c)\nbuilt with Clang 20.1.8 for Windows x86_64\n"
  check("version_line picks llama-server's version line", health.version_line(llama) == "version: 0.5.0-dev (build 11149, commit d2e54583c)", health.version_line(llama))
  check("version_line keeps a first line that names the version", health.version_line("git version 2.54.0.windows.1\n") == "git version 2.54.0.windows.1")
  check("version_line falls back to the first line", health.version_line("ripgrep 15.2.0 (rev e89fff89ac)\r\n+SIMD +AVX\r\n") == "ripgrep 15.2.0 (rev e89fff89ac)")
  check("version_line is nil for no output", health.version_line("") == nil and health.version_line(nil) == nil)
end
local llama_line = text:match("llama%-server: [^\n]*")
check("llama-server line is not a log line", llama_line == nil or not llama_line:find("initializing", 1, true), llama_line or "llama-server not installed here")
check("mentions the config link", text:find("config: ", 1, true) ~= nil)
check("mentions the data folder", text:find("data: ", 1, true) ~= nil)
check("mentions the window", text:find("window", 1, true) ~= nil)
-- Headless, nothing attached: the window line says so rather than claiming a channel.
check("window state is honest headless", vim.g.nvs_shell or text:find("not inside the nvs.ide window", 1, true) ~= nil)
finish()
