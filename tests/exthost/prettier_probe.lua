-- Opt-in probe: a headless Neovim starts the extension host with the Prettier
-- extension and formats a JavaScript buffer through vim.lsp.buf.format.
--
-- It needs: node on PATH, the Prettier extension (esbenp.prettier-vscode from Open
-- VSX) unpacked at <data>/vsx/extensions/esbenp.prettier-vscode/ (the vsix's
-- extension/ folder contents), and the sandbox environment so it never touches a
-- real profile. From the repo root, in PowerShell:
--
--   $sb = "$env:LOCALAPPDATA\Temp\nvs-sb-host"
--   $env:XDG_CONFIG_HOME = "$sb\config"; $env:XDG_DATA_HOME = "$sb\data"
--   $env:XDG_STATE_HOME = "$sb\state";   $env:XDG_CACHE_HOME = "$sb\cache"
--   $env:NVIM_APPNAME = "nvs-ide";       $env:NVS_TEST = "1"
--   nvim --headless -c "luafile tests/exthost/prettier_probe.lua"
--
-- (tests/run.ps1 -Sandbox $sb creates that sandbox and links its config to runtime/.)
-- It prints PASS or FAIL lines and exits with the number of failures; a watchdog
-- exits with 2 after 60 s so a stuck request can never hang the run.

local fails = 0
local function check(name, ok, detail)
  if ok then
    io.write("PASS " .. name .. "\n")
  else
    fails = fails + 1
    io.write("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "") .. "\n")
  end
  io.flush()
end

vim.defer_fn(function()
  io.write("FAIL watchdog: 60 s elapsed\n")
  io.flush()
  os.exit(2)
end, 60000)

-- The probe edits a temp file and exits with the buffer modified; no swap file may
-- be left behind for the next run to trip over.
vim.o.swapfile = false

local data = vim.fn.stdpath("data")
local runtime = vim.fn.stdpath("config")
local vsx = data .. "/vsx"
local ext = vsx .. "/extensions/esbenp.prettier-vscode"
local host = runtime .. "/exthost/host.js"
local logdir = vsx .. "/logs"
vim.fn.mkdir(logdir, "p")
local logfile = logdir .. "/esbenp.prettier-vscode.log"

check("host.js is where the runtime says", vim.fn.filereadable(host) == 1, host)
check("the Prettier extension is unpacked", vim.fn.filereadable(ext .. "/package.json") == 1, ext)
check("node is on PATH", vim.fn.executable("node") == 1)
if fails > 0 then
  os.exit(fails)
end

-- A short temp project with a .prettierrc that differs from Prettier's defaults, so
-- the output proves the config file was read, not just that something formatted.
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ '{ "singleQuote": true, "semi": false }' }, root .. "/.prettierrc")
local file = root .. "/test.js"
vim.fn.writefile({ "const a = {b:1,c:[1,2,3]}; function f(){return a}" }, file)

vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "javascript"
local before = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
io.write("before: " .. vim.inspect(before) .. "\n")

local id = vim.lsp.start({
  name = "vsx_prettier",
  cmd = { "node", host, "--extension", ext, "--data", vsx, "--log", logfile, "--stdio" },
  root_dir = root,
  filetypes = { "javascript" },
})
check("vim.lsp.start returned a client id", id ~= nil, id)

local attached = vim.wait(20000, function()
  local c = id and vim.lsp.get_client_by_id(id)
  return c ~= nil and c.initialized and vim.lsp.buf_is_attached(0, id)
end, 50)
check("client initialized and attached within 20 s", attached)

local client = id and vim.lsp.get_client_by_id(id)
local caps = client and client.server_capabilities or {}
check("server announces documentFormattingProvider", caps.documentFormattingProvider == true, vim.inspect(caps.documentFormattingProvider))
check("server announces documentRangeFormattingProvider", caps.documentRangeFormattingProvider == true, vim.inspect(caps.documentRangeFormattingProvider))

vim.lsp.buf.format({ timeout_ms = 20000, id = id })

local after = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
io.write("after:  " .. vim.inspect(after) .. "\n")
local expected = "const a = { b: 1, c: [1, 2, 3] }\nfunction f() {\n  return a\n}"
check("buffer holds Prettier's output with the .prettierrc applied", after == expected, vim.inspect(after))
check("buffer changed", after ~= before)

-- The log is the host's; it must exist and name the extension.
local log = vim.fn.filereadable(logfile) == 1 and table.concat(vim.fn.readfile(logfile), "\n") or ""
check("host log written", log:find("esbenp.prettier%-vscode", 1) ~= nil, logfile)

if client then
  client:stop()
end
vim.wait(3000, function()
  return client == nil or client:is_stopped()
end, 50)
check("client stopped", client == nil or client:is_stopped())
vim.fn.delete(root, "rf")
io.write(string.format("%d failed\n", fails))
io.flush()
os.exit(fails)
