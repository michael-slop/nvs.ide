-- bridge.lua: streams workbench state from Neovim to the nvs.ide shell.
-- Loaded only when the shell is attached (vim.g.nvs_shell). Everything goes out as
-- vim.rpcnotify(channel, "nvs", event, payload); the shell never polls.
local M = {}

local chan = vim.g.nvs_channel

-- Errors here would vanish (nothing shows a failed rpcnotify or a timer callback's error
-- inside the window), so they go to stdpath("log")/nvs-bridge.log as well as :messages.
local function log_error(where, err)
  local line = ("%s bridge %s: %s"):format(os.date("%Y-%m-%d %H:%M:%S"), where, tostring(err))
  pcall(function()
    local f = io.open(vim.fn.stdpath("log") .. "/nvs-bridge.log", "a")
    if f then
      f:write(line, "\n")
      f:close()
    end
  end)
  vim.schedule(function()
    vim.notify(line, vim.log.levels.WARN, { title = "nvs.ide" })
  end)
end

-- NVS_BRIDGE_TRACE=1 also records every event sent, with its encoded size.
local trace = vim.env.NVS_BRIDGE_TRACE == "1"

local function send(event, payload)
  if chan then
    local ok, err = pcall(vim.rpcnotify, chan, "nvs", event, payload)
    if not ok then
      log_error("send " .. tostring(event), err)
    elseif trace then
      local eok, enc = pcall(vim.mpack.encode, payload)
      log_error("trace", ("sent %s (%s bytes)"):format(tostring(event), eok and #enc or "?"))
    end
  end
end

-- Run a callback and report its error instead of losing it.
local function guarded(where, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      log_error(where, err)
    end
  end
end

local function buffer_entry(buf, current)
  local name = vim.api.nvim_buf_get_name(buf)
  return {
    bufnr = buf,
    path = name,
    name = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]",
    modified = vim.bo[buf].modified,
    filetype = vim.bo[buf].filetype,
    buftype = vim.bo[buf].buftype,
    current = buf == current,
  }
end

local function diagnostic_counts(buf)
  local counts = { error = 0, warn = 0, info = 0, hint = 0 }
  local names = { [vim.diagnostic.severity.ERROR] = "error", [vim.diagnostic.severity.WARN] = "warn",
    [vim.diagnostic.severity.INFO] = "info", [vim.diagnostic.severity.HINT] = "hint" }
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local k = names[d.severity]
    if k then
      counts[k] = counts[k] + 1
    end
  end
  return counts
end

local function branch()
  local head = vim.b.gitsigns_head
  if head and head ~= "" then
    return head
  end
  return vim.g.gitsigns_head or ""
end

-- The whole workbench state in one small table. Cheap enough to send on every change.
function M.state()
  local current = vim.api.nvim_get_current_buf()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.api.nvim_buf_is_loaded(buf) then
      table.insert(buffers, buffer_entry(buf, current))
    end
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local clients = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = current })) do
    table.insert(clients, c.name)
  end
  local ok, state = pcall(require, "nvs.state")
  local nvs = ok and state.data or {}
  return {
    mode = vim.api.nvim_get_mode().mode,
    cwd = vim.fn.getcwd(),
    buffers = buffers,
    current = current,
    cursor = { line = cursor[1], col = cursor[2] + 1 },
    branch = branch(),
    diagnostics = diagnostic_counts(nil),
    buffer_diagnostics = diagnostic_counts(current),
    lsp = clients,
    stage = nvs.stage or 2,
    coach = nvs.coach or "three",
    welcomed = nvs.welcomed == true,
    ai = { enabled = nvs.ai and nvs.ai.enabled or false, model = nvs.ai and nvs.ai.chat_model or "" },
  }
end

-- The Settings screen's schema and values (lua/nvs/prefs.lua).
function M.settings()
  local ok, prefs = pcall(require, "nvs.prefs")
  return ok and prefs.describe() or { categories = {}, settings = {}, keybindings = {} }
end

-- The Plugins screen's lists (lua/nvs/plugins.lua).
function M.plugins()
  local ok, plugins = pcall(require, "nvs.plugins")
  return ok and plugins.describe() or { plugins = {}, extras = {} }
end

-- The shell asks for a fresh copy of something.
function M.push(what)
  if what == "settings" then
    send("settings", M.settings())
  elseif what == "plugins" then
    send("plugins", M.plugins())
  elseif what == "diagnostics" then
    send("diagnostics", M.diagnostics())
  else
    send("state", M.state())
  end
end

-- Ask the window to show one of its screens: "settings", "plugins", "learn", "welcome".
-- Returns false when no window is attached (terminal Neovim), so the caller can fall back.
function M.open(what)
  if not chan then
    return false
  end
  send("open", what)
  return true
end

-- Shell actions that need an answer back.
function M.set_setting(id, value)
  local ok, err = require("nvs.prefs").set(id, value)
  if not ok then
    vim.notify(("Setting %s: %s"):format(tostring(id), tostring(err)), vim.log.levels.WARN, { title = "nvs.ide" })
  end
end

function M.import_vscode()
  local report = require("nvs.prefs").import_vscode()
  send("settings_report", report)
  local n = #report.applied + #report.keys
  vim.notify(report.error or ("Imported %d setting%s from VS Code; %d had no equivalent."):format(n, n == 1 and "" or "s", #report.skipped), report.error and vim.log.levels.WARN or vim.log.levels.INFO, { title = "nvs.ide" })
end

function M.plugin_action(what, name)
  require("nvs.plugins").action(what, name)
  vim.defer_fn(function()
    send("plugins", M.plugins())
  end, 300)
end

-- VS Code extensions (docs/extensions.md). Neovim -> shell: "vsx" (installed + status),
-- "vsx_search" (results), "vsx_progress" (install stages).
function M.vsx_state()
  local ok, vsx = pcall(require, "nvs.vsx")
  if not ok then
    return { installed = {}, status = { host = { running = false, mode = "never", node = nil, extensions = 0 }, registry = "" } }
  end
  return { installed = vsx.list(), status = vsx.status() }
end

function M.push_vsx()
  local ok, state = pcall(M.vsx_state)
  if not ok then
    return log_error("vsx_state", state)
  end
  send("vsx", state)
end

-- Shell -> Neovim: vsx("search", query) | vsx("install", id) | vsx("uninstall", id)
-- | vsx("enable", id, bool) | vsx("refresh")
function M.vsx(action, a, b)
  local ok, vsx = pcall(require, "nvs.vsx")
  if not ok then
    -- The first line of a require error is the reason; the rest is the search path.
    local why = tostring(vsx):match("^[^\n]*") or tostring(vsx)
    return send("vsx_search", { query = a or "", results = {}, error = "The extension system did not load: " .. why })
  end
  if action == "search" then
    vsx.search(a or "", function(err, results)
      send("vsx_search", { query = a or "", results = results or {}, error = err })
    end)
  elseif action == "install" then
    vsx.install(a, function(err)
      if err then
        vim.notify(err, vim.log.levels.WARN, { title = "nvs.ide · extensions" })
      end
      M.push_vsx()
    end)
  elseif action == "uninstall" then
    vsx.uninstall(a)
    M.push_vsx()
  elseif action == "enable" then
    vsx.set_enabled(a, b == true)
    M.push_vsx()
  else
    M.push_vsx()
  end
end

-- Every diagnostic in every buffer, for the Problems panel.
function M.diagnostics()
  local names = { [vim.diagnostic.severity.ERROR] = "error", [vim.diagnostic.severity.WARN] = "warn",
    [vim.diagnostic.severity.INFO] = "info", [vim.diagnostic.severity.HINT] = "hint" }
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    local path = vim.api.nvim_buf_get_name(d.bufnr)
    table.insert(out, {
      bufnr = d.bufnr,
      path = path,
      file = vim.fn.fnamemodify(path, ":."),
      lnum = d.lnum + 1,
      col = d.col + 1,
      severity = names[d.severity] or "info",
      message = (d.message or ""):gsub("\n.*", ""),
      source = d.source or "",
    })
  end
  table.sort(out, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.lnum < b.lnum
  end)
  return out
end

local pending = false
local function push_state()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    send("state", M.state())
  end)
end

function M.setup()
  if not chan then
    return
  end
  local group = vim.api.nvim_create_augroup("nvs_bridge", { clear = true })
  vim.api.nvim_create_autocmd(
    { "ModeChanged", "BufEnter", "BufAdd", "BufDelete", "BufFilePost", "BufModifiedSet", "BufWritePost", "DirChanged", "LspAttach", "LspDetach", "TabEnter", "WinEnter" },
    { group = group, callback = push_state }
  )
  -- Cursor position for the status bar, at most every 100 ms.
  local timer = nil
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      if timer then
        return
      end
      timer = vim.defer_fn(function()
        timer = nil
        push_state()
      end, 100)
    end,
  })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function()
      push_state()
      vim.schedule(function()
        send("diagnostics", M.diagnostics())
      end)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NvsStateChanged",
    callback = push_state,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NvsSettingsChanged",
    callback = function()
      vim.schedule(function()
        send("settings", M.settings())
      end)
    end,
  })
  -- Plugin state changes: installs, updates, checks and lazy loads (throttled).
  local plugins_timer = nil
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "LazyInstall", "LazyUpdate", "LazySync", "LazyClean", "LazyCheck", "LazyLoad", "LazyDone" },
    callback = function()
      if plugins_timer then
        return
      end
      plugins_timer = vim.defer_fn(function()
        plugins_timer = nil
        send("plugins", M.plugins())
      end, 500)
    end,
  })
  -- Install progress and state changes from the extension system.
  pcall(function()
    local vsx = require("nvs.vsx")
    vsx.on_progress = function(id, stage, message)
      send("vsx_progress", { id = id, stage = stage, message = message or "" })
      if stage == "done" or stage == "error" then
        vim.schedule(M.push_vsx)
      end
    end
  end)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NvsVsxChanged",
    callback = function()
      vim.schedule(M.push_vsx)
    end,
  })
  -- Say hello once everything is loaded. nvs.setup() runs at VeryLazy, which is after
  -- VimEnter in the window, so the autocmd is only for the rare early load; the direct
  -- call is the path that actually runs.
  local function hello()
    push_state()
    send("diagnostics", M.diagnostics())
    send("settings", M.settings())
    vim.defer_fn(guarded("startup push", function()
      send("plugins", M.plugins())
      M.push_vsx()
    end), 1000)
  end
  if vim.v.vim_did_enter == 1 then
    hello()
  else
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = hello })
  end
end

return M
