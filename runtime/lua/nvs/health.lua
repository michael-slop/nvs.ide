-- :checkhealth nvs — the tools nvs.ide needs, where its folders are, and whether the
-- window is attached. Neovim finds this file by its path (lua/nvs/health.lua) and calls
-- check(). It must never raise, so every probe is guarded. Install advice is winget on
-- Windows and apt / pacman elsewhere, the two Linux families the release is tested on.
local M = {}

local health = vim.health

local WINDOWS = vim.fn.has("win32") == 1

-- How to install something here: the winget command on Windows, the Linux advice elsewhere.
local function install(winget, linux)
  return WINDOWS and ("winget install " .. winget) or linux
end

local function on_path(name)
  local path = vim.fn.exepath(name)
  return path ~= "" and path or nil
end

-- The line of a tool's --version output that names its version: the first line that
-- contains "version", else the first line. llama-server logs a startup line
-- ("0.00.000.682 I srv  llama_server: initializing ...") before "version: 0.5.0-dev
-- (build 11149, ...)", all on stderr; git, rg, gcc and node say it on their first line.
-- nil for empty output. Pure, so tests/verify_health.lua can check it on fixed text.
function M.version_line(text)
  local first
  for line in (text or ""):gmatch("[^\r\n]+") do
    first = first or line
    if line:lower():find("version", 1, true) then
      return line
    end
  end
  return first
end

-- What `exe --version` says, through version_line, or nil when it cannot run. Bounded,
-- never raises. stdout and stderr both count: llama-server prints everything on stderr.
local function version_of(exe, args)
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ exe }, args or { "--version" }), { text = true, timeout = 5000 }):wait()
  end)
  if not ok or type(res) ~= "table" or res.code ~= 0 then
    return nil
  end
  return M.version_line((res.stdout or "") .. (res.stderr or ""))
end

-- One tool: the first of `names` found on PATH is reported with its version. None found is
-- reported at `level` ("error", "warn" or "info") with the install line as the advice.
local function tool(label, names, why, install, level)
  for _, name in ipairs(names) do
    local path = on_path(name)
    if path then
      local v = version_of(path, name == "zig" and { "version" } or nil)
      health.ok(("%s: %s%s"):format(label, path, v and ("  (" .. v .. ")") or ""))
      return path
    end
  end
  local msg = ("%s not found: %s"):format(label, why)
  if level == "error" then
    health.error(msg, install)
  elseif level == "info" then
    health.info(msg .. ". " .. install)
  else
    health.warn(msg, install)
  end
  return nil
end

function M.check()
  health.start("nvs.ide")
  local v = vim.version()
  local version = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. version)
  elseif vim.fn.has("nvim-0.10") == 1 then
    health.warn("Neovim " .. version .. " runs nvs.ide, but 0.11 or newer is what it is tested on", install("Neovim.Neovim", "the Linux release bundles Neovim 0.12; distro packages are often older (Ubuntu 24.04 has 0.9): github.com/neovim/neovim/releases"))
  else
    health.error("Neovim " .. version .. " is too old: nvs.ide needs 0.10 or newer", install("Neovim.Neovim", "the Linux release bundles Neovim 0.12; distro packages are often older (Ubuntu 24.04 has 0.9): github.com/neovim/neovim/releases"))
  end
  local ok_state, state = pcall(require, "nvs.state")
  if ok_state and type(state.data) == "table" and state.data.stage then
    local ok_stages, stages = pcall(require, "nvs.stages")
    local name = ok_stages and type(stages.names) == "table" and stages.names[state.data.stage] or ""
    health.info(("stage %s %s (:NvsStage changes it)"):format(tostring(state.data.stage), name))
  end

  health.start("Tools")
  tool("git", { "git" }, "LazyVim clones and updates its plugins with git", install("Git.Git", "sudo apt install git, or sudo pacman -S git"), "error")
  tool("rg (ripgrep)", { "rg" }, "the Search view and the pickers grep with it", install("BurntSushi.ripgrep.MSVC", "sudo apt install ripgrep, or sudo pacman -S ripgrep"), "warn")
  -- Debian and Ubuntu name the binary fdfind.
  tool("fd", { "fd", "fdfind" }, "the file pickers list files with it (slower without it)", install("sharkdp.fd", "sudo apt install fd-find, or sudo pacman -S fd"), "warn")
  tool("tree-sitter", { "tree-sitter" }, "syntax parsers are built with the tree-sitter CLI", install("tree-sitter.tree-sitter-cli", "nvim-treesitter needs 0.26.1 or newer: sudo pacman -S tree-sitter-cli, or tree-sitter-linux-x64 from github.com/tree-sitter/tree-sitter/releases (Ubuntu 24.04's package is 0.20)"), "warn")
  tool("C compiler", { "gcc", "clang", "cl", "zig", "cc" }, "syntax parsers are compiled with it", install("BrechtSanders.WinLibs.POSIX.UCRT", "sudo apt install build-essential, or sudo pacman -S base-devel"), "warn")
  tool("curl", { "curl" }, "models, extensions and language servers are downloaded with it", WINDOWS and "Windows 10 and newer ship it" or "sudo apt install curl, or sudo pacman -S curl", "warn")
  tool("node", { "node" }, "VS Code extensions need it: the extension host and bundled language servers run in Node", install("OpenJS.NodeJS.LTS", "sudo apt install nodejs, or sudo pacman -S nodejs (18 or newer)"), "warn")
  if not WINDOWS and vim.fn.has("mac") == 0 then
    local clip = vim.g.clipboard
    if type(clip) == "table" and clip.name == "nvs-ide" then
      health.ok("clipboard: served by the nvs.ide window (no wl-copy or xclip needed)")
    else
      tool("clipboard tool", { "wl-copy", "xclip", "xsel" }, "outside the window, copy and paste reach the system clipboard through one of these", "sudo apt install wl-clipboard xclip, or sudo pacman -S wl-clipboard xclip", "warn")
    end
  end
  tool("lazygit", { "lazygit" }, "Space g g opens it", install("JesseDuffield.lazygit", "sudo pacman -S lazygit, or a release from github.com/jesseduffield/lazygit"), "info")
  -- llama-server honours :NvsAI server <path>, so ask ai.lua first and PATH second.
  local ok_ai, server = pcall(function()
    return require("nvs.ai").server_path()
  end)
  if not (ok_ai and server) then
    server = on_path("llama-server")
  end
  if server then
    local sv = version_of(server)
    health.ok("llama-server: " .. server .. (sv and ("  (" .. sv .. ")") or ""))
  else
    health.info("llama-server not found: local AI (Ask's model fallback, ghost text) stays off until llama.cpp is installed. " .. install("ggml.llamacpp", "llama.cpp: a release from github.com/ggml-org/llama.cpp, or brew install llama.cpp") .. ", then :NvsAI on; :NvsAI server <path> points at a copy that is not on PATH")
  end

  health.start("Folders")
  local config = vim.fn.stdpath("config")
  local link = vim.uv.fs_lstat(config)
  if not link then
    health.error(("config: %s does not exist"):format(config), "The nvs.ide window links it to its runtime/ folder on the first start. Without the window, scripts/try.ps1 makes the link.")
  elseif link.type == "link" then
    local target = vim.uv.fs_readlink(config) or "?"
    if vim.uv.fs_stat(target .. "/init.lua") then
      health.ok(("config: %s -> %s"):format(config, target))
    else
      health.error(("config: %s -> %s, which has no init.lua"):format(config, target), "Remove the link and start the nvs.ide window again; it makes a new one to its runtime/.")
    end
  elseif vim.uv.fs_stat(config .. "/init.lua") then
    health.info(("config: %s is a folder of its own, not a link to nvs.ide's runtime/ (fine, as long as you keep it up to date yourself)"):format(config))
  else
    health.error(("config: %s exists but has no init.lua"):format(config), "Move it aside and start the nvs.ide window again; it links the folder to its runtime/.")
  end
  local data = vim.fn.stdpath("data")
  local plugins = vim.fn.glob(data .. "/lazy/*", false, true)
  if #plugins > 0 then
    health.ok(("data: %s (%d plugins in lazy/)"):format(data, #plugins))
  elseif vim.uv.fs_stat(data) then
    health.warn(("data: %s has no plugins in lazy/ yet"):format(data), "They install on the first start (about a minute); :Lazy sync does it by hand.")
  else
    health.warn(("data: %s does not exist yet"):format(data), "Neovim creates it on the first start.")
  end
  local ok_models, models = pcall(function()
    return require("nvs.ai").models_dir()
  end)
  if ok_models and type(models) == "string" then
    local n = #vim.fn.glob(models .. "/*.gguf", false, true)
    health.info(("models: %s (%d GGUF files; :NvsModel pull adds one)"):format(models, n))
  end
  local vsx = data .. "/vsx/vsx.json"
  if vim.uv.fs_stat(vsx) then
    local ok_read, count = pcall(function()
      local decoded = vim.json.decode(table.concat(vim.fn.readfile(vsx), "\n"))
      return type(decoded) == "table" and type(decoded.extensions) == "table" and #decoded.extensions or 0
    end)
    health.info(("extensions: %s (%s installed)"):format(data .. "/vsx", ok_read and tostring(count) or "unreadable vsx.json"))
  end

  health.start("Window")
  if vim.g.nvs_shell then
    health.ok("the nvs.ide window is attached" .. (vim.g.nvs_channel and (" on channel " .. tostring(vim.g.nvs_channel)) or ""))
  else
    health.info("not inside the nvs.ide window (a terminal or Neovide): editing, Ask and the lessons work here; the workbench, Settings and Plugins screens need the window (nvs-ide.exe)")
  end
end

return M
