-- Live local-AI checks. Opt-in: they need llama-server, a GPU and a folder of GGUF
-- models, so tests/run.ps1 never runs them. Set up a sandbox the way tests/run.ps1 does
-- (run it once, then set the same XDG_* / NVIM_APPNAME / NVS_TEST variables in your
-- shell) and in the sandbox's data\nvs-ide-data\nvs-ide.json set
--   "ai": { "enabled": true, "llamacpp": { "models_dir": "<folder with a qwen2.5-coder GGUF>" } }
-- plus "server": "<path>" if llama-server is not on PATH. The 1.5b Q4_K_M model is
-- enough; the checks pick the smallest file in the folder. Then, from the repo root:
--   nvim --headless -c "luafile tests/ai_live.lua"
-- NVS_AI_LIVE picks the groups, comma separated. Default: process,install.
--   process  the managed server's lifecycle: a chat loads a model child, stop kills the
--            whole tree, a port change or restart keeps one server, a pull replaces the
--            model that is loaded (on a temp copy of it), quitting leaves none
--   install  a downloaded file replaces an existing model, and never loses it when the
--            old file or the download is held open (temp folder, no server)
--   net      resolve, pull (downloads ~340 MB INTO the models folder), Ask, minuet
--   all      everything
-- Every line printed starts with PASS or FAIL. Nothing is left running at the end: the
-- checks kill every llama-server they started, even when the code under test did not.
local out = {}
local function check(name, ok, detail)
  table.insert(out, (ok and "PASS " or "FAIL ") .. name .. (detail and ("  (" .. tostring(detail):gsub("\n", " / "):sub(1, 220) .. ")") or ""))
end

local groups = {}
for g in (vim.env.NVS_AI_LIVE or "process,install"):gmatch("[^,%s]+") do
  groups[g] = true
end
if groups.all then
  groups = { process = true, install = true, net = true }
end

vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
local ai = require("nvs.ai")
local state = require("nvs.state")
local win = vim.fn.has("win32") == 1

-- Every llama-server on the machine, by pid: tasklist on Windows, pgrep elsewhere.
local list_cmd = win and { "tasklist", "/FI", "IMAGENAME eq llama-server.exe", "/FO", "CSV", "/NH" } or { "pgrep", "-x", "llama-server" }
local function parse_pids(text)
  local pids = {}
  for pid in (text or ""):gmatch(win and '"llama%-server%.exe","(%d+)"' or "(%d+)") do
    table.insert(pids, tonumber(pid))
  end
  table.sort(pids)
  return pids
end
local function server_pids()
  return parse_pids(vim.system(list_cmd, { text = true }):wait().stdout)
end
local function minus(a, b)
  local set = {}
  for _, p in ipairs(b) do
    set[p] = true
  end
  return vim.tbl_filter(function(p)
    return not set[p]
  end, a)
end
-- llama-servers that were already running are not ours and stay out of every count.
local foreign = server_pids()
local function ours()
  return minus(server_pids(), foreign)
end

-- Run fn(done) and pump the loop until done(...) is called or ms pass. Returns the
-- values done received (n = how many), or nil on timeout.
local function collect(ms, fn)
  local got
  fn(function(...)
    got = { n = select("#", ...), ... }
  end)
  vim.wait(ms, function()
    return got ~= nil
  end, 100)
  return got
end
local function err_of(r)
  return r and (r[1] or "ok") or "timeout"
end

-- Collect notifications instead of showing them. Returns the list and a function that
-- puts vim.notify back.
local function capture_notify()
  local notes, orig = {}, vim.notify
  vim.notify = function(m)
    table.insert(notes, tostring(m))
  end
  return notes, function()
    vim.notify = orig
  end
end
local function noted(notes, s)
  for _, n in ipairs(notes) do
    if n:find(s, 1, true) then
      return true
    end
  end
  return false
end

local function finish(code)
  -- os.exit skips VimLeavePre, so end the server here, then kill anything the code
  -- under test left behind: no llama-server may outlive this run.
  local kill = ai.stop()
  if kill and kill.wait then
    kill:wait(5000)
  end
  vim.wait(500)
  for _, pid in ipairs(ours()) do
    local cmd = win and { "taskkill", "/T", "/F", "/PID", tostring(pid) } or { "kill", "-9", tostring(pid) }
    vim.system(cmd, { text = true }):wait(5000)
    table.insert(out, ("FAIL cleanup: killed llama-server %d that the test left running"):format(pid))
  end
  io.write(table.concat(out, "\n") .. "\n")
  io.flush()
  os.exit(code)
end
-- A prompt or a request that never returns would hang a headless run; timers still
-- fire while vim.wait waits, so bail out.
local cap = groups.net and 900 or 120
vim.defer_fn(function()
  table.insert(out, ("FAIL hung %d s (a step never finished)"):format(cap))
  finish(2)
end, cap * 1000)

local a = state.data.ai
check("backend is llamacpp", a.backend == "llamacpp", a.backend)
check("server found", ai.server_path() ~= nil, ai.server_path())

---------------------------------------------------------------------------
-- process: the managed server's lifecycle
---------------------------------------------------------------------------
if groups.process then
  local keep = { enabled = a.enabled, chat_model = a.chat_model, port = a.llamacpp.port, models_dir = a.llamacpp.models_dir }
  -- Status must never start the GPU server: it captures the notification instead.
  local function status_off()
    local notes, restore = capture_notify()
    a.enabled = false
    ai.status()
    vim.wait(2500, function()
      return #notes > 0
    end, 100)
    restore()
    return notes[1] or "(no notification)"
  end
  local note = status_off()
  check("status with AI off starts nothing", #ours() == 0, vim.inspect(ours()))
  check("status with AI off says the server is not running", note:find("not running", 1, true) ~= nil, note)
  check("status with AI off lists the models on disk", note:find("Models on disk: %S") ~= nil and note:find("qwen") ~= nil, note)
  a.enabled = true
  -- The smallest model on disk keeps the load short. Its id is the file name without .gguf.
  local files = vim.fn.glob(ai.models_dir() .. "/*.gguf", false, true)
  table.sort(files, function(x, y)
    return vim.fn.getfsize(x) < vim.fn.getfsize(y)
  end)
  check("a model is on disk", #files > 0, ai.models_dir())
  a.chat_model = files[1] and (vim.fs.basename(files[1]):gsub("%.gguf$", "")) or ""

  -- ensure starts the router; a chat makes it load a model child.
  local r = collect(60000, ai.ensure)
  check("ensure starts the router", r and r[1] == nil, err_of(r))
  local router = ours()
  check("one llama-server after ensure", #router == 1, vim.inspect(router))
  local t0 = vim.uv.now()
  r = collect(80000, function(done)
    ai.chat({ { role = "user", content = "Say hi." } }, done)
  end)
  check("chat answers", r and r[1] == nil and type(r[2]) == "string" and r[2] ~= "", r and (r[1] or r[2]) or "timeout")
  local tree = ours()
  check("chat loaded a model child", #tree >= 2, ("%.1fs, pids %s"):format((vim.uv.now() - t0) / 1000, vim.inspect(tree)))
  note = status_off()
  check("status with AI off reports a running server", note:find("running (pid", 1, true) ~= nil, note)
  a.enabled = true

  -- stop must take the whole tree, not only the router.
  r = collect(15000, ai.stop)
  check("stop calls back once the server is gone", r ~= nil, r and "called back" or "no callback in 15 s")
  vim.wait(500)
  local left = ours()
  check("stop leaves no llama-server", #left == 0, ("left %s of %s"):format(vim.inspect(left), vim.inspect(tree)))

  -- A port change: one server at a time, and the old server's exit callback (which
  -- lands after the new one started) must not drop the new handle.
  r = collect(60000, ai.ensure)
  check("ensure starts the router again", r and r[1] == nil, err_of(r))
  local first = ours()
  ai.command("port 8013")
  r = collect(60000, ai.ensure)
  check("ensure on the new port starts a router", r and r[1] == nil, err_of(r))
  check("address follows the port", ai.base_url() == "http://127.0.0.1:8013", ai.base_url())
  local second = ours()
  check("port change keeps one server", #second == 1 and not vim.tbl_contains(second, first[1]), ("%s then %s"):format(vim.inspect(first), vim.inspect(second)))
  vim.wait(3000) -- the old server's exit callback has landed by now
  r = collect(60000, ai.ensure)
  check("ensure after the old exit callback is a no-op", r and r[1] == nil, err_of(r))
  vim.wait(1500) -- a duplicate would be up by now
  local third = ours()
  check("no duplicate after the old exit callback", #third == 1 and third[1] == second[1], ("%s then %s"):format(vim.inspect(second), vim.inspect(third)))

  -- restart on the same port: the new server must be able to bind it.
  r = collect(60000, ai.restart)
  check("restart comes back", r and r[1] == nil, err_of(r))
  local fourth = ours()
  check("restart keeps one server, a new one", #fourth == 1 and fourth[1] ~= third[1], ("%s then %s"):format(vim.inspect(third), vim.inspect(fourth)))
  r = collect(15000, ai.stop)
  vim.wait(500)
  check("stop after the port change leaves none", #ours() == 0, vim.inspect(ours()))
  ai.command("port " .. keep.port)

  -- A pull that replaces the model that is loaded: llama-server shares its file, so
  -- the swap happens under it and the router restarts to list the new file. A temp
  -- COPY of the smallest model stands in; the models folder is only read (curl copies
  -- the same file back in over file://).
  local live_dir = vim.fs.normalize(vim.fn.stdpath("cache") .. "/nvs-tests/live-" .. vim.uv.os_getpid())
  vim.fn.delete(live_dir, "rf")
  vim.fn.mkdir(live_dir, "p")
  local live = live_dir .. "/live.gguf"
  local copied, cerr = vim.uv.fs_copyfile(files[1], live)
  check("a temp copy of the smallest model", copied == true, cerr or live)
  a.llamacpp.models_dir, a.chat_model = live_dir, "live"
  r = collect(80000, function(done)
    ai.chat({ { role = "user", content = "Say hi." } }, done)
  end)
  check("chat loads the copy", r and r[1] == nil and type(r[2]) == "string" and r[2] ~= "", r and (r[1] or r[2]) or "timeout")
  local loaded = ours()
  local resolve = ai.resolve
  ai.resolve = function(_, cb)
    cb(nil, { { url = "file:///" .. files[1], file = "live.gguf" } })
  end
  local notes, restore = capture_notify()
  r = collect(80000, function(done)
    ai.pull("stub", done)
  end)
  restore()
  ai.resolve = resolve
  check("pull replaces the loaded model", r and r[1] == nil and r[2] == "live.gguf", err_of(r))
  check("pull of the loaded model says ready", noted(notes, "Model ready: live") and not noted(notes, "Couldn't"), vim.inspect(notes))
  check("pull of the loaded model leaves no .old or .part", vim.fn.filereadable(live .. ".old") == 0 and vim.fn.filereadable(live .. ".part") == 0
    and vim.fn.getfsize(live) == vim.fn.getfsize(files[1]), vim.inspect(vim.tbl_map(vim.fs.basename, vim.fn.glob(live_dir .. "/*", false, true))))
  local after_pull = ours()
  check("pull restarted the router", #after_pull == 1 and not vim.tbl_contains(loaded, after_pull[1]), ("%s then %s"):format(vim.inspect(loaded), vim.inspect(after_pull)))
  r = collect(80000, function(done)
    ai.chat({ { role = "user", content = "Say hi." } }, done)
  end)
  check("the replaced model answers", r and r[1] == nil and type(r[2]) == "string" and r[2] ~= "", r and (r[1] or r[2]) or "timeout")
  r = collect(15000, ai.stop)
  vim.wait(500)
  check("stop after the pull leaves none", #ours() == 0, vim.inspect(ours()))
  a.llamacpp.models_dir = keep.models_dir
  a.chat_model = (vim.fs.basename(files[1]):gsub("%.gguf$", ""))
  vim.fn.delete(live_dir, "rf")

  -- Quitting: a child Neovim starts a server, chats so a model child exists, then
  -- :qa!. VimLeavePre must end the whole tree before Neovim is gone. The child prints
  -- the llama-servers it saw; none of them may be alive afterwards.
  local script = vim.fn.stdpath("cache") .. "/nvs-tests/ai_quit.lua"
  vim.fn.mkdir(vim.fs.dirname(script), "p")
  local child = ([==[
local ai = require("nvs.ai")
local a = require("nvs.state").data.ai
a.enabled, a.chat_model = true, "MODEL"
local done
ai.chat({ { role = "user", content = "Say hi." } }, function(e, t) done = e or t end)
vim.wait(80000, function() return done ~= nil end, 200)
local res = vim.system(LIST, { text = true }):wait()
io.write("CHAT " .. tostring(done):gsub("[\r\n]+", " ") .. "\n")
io.write("TREE " .. (res.stdout or ""):gsub("[\r\n]+", " ") .. "\n")
vim.cmd("qa!")
]==]):gsub("MODEL", a.chat_model):gsub("LIST", vim.inspect(list_cmd))
  vim.fn.writefile(vim.split(child, "\n"), script)
  local res = vim.system({ "nvim", "--headless", "-c", "luafile " .. script }, { text = true }):wait(85000)
  local o = res.stdout or ""
  check("child nvim chatted then quit", res.code == 0 and o:find("CHAT ") ~= nil and not o:find("CHAT nil"), ("code %s: %s"):format(res.code, o:sub(1, 200)))
  local child_tree = minus(parse_pids(o:match("TREE ([^\n]*)")), foreign)
  check("child nvim had a router and a model child", #child_tree >= 2, vim.inspect(child_tree))
  vim.wait(1000)
  local after = ours()
  check("quitting leaves no llama-server", #after == 0, ("left %s of %s"):format(vim.inspect(after), vim.inspect(child_tree)))

  a.enabled, a.chat_model = keep.enabled, keep.chat_model
  state.save()
end

---------------------------------------------------------------------------
-- install: a download replaces an existing model file, and never loses it
---------------------------------------------------------------------------
if groups.install then
  local dir = vim.fs.normalize(vim.fn.stdpath("cache") .. "/nvs-tests/models-" .. vim.uv.os_getpid())
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  local dest, part, old = dir .. "/fake.gguf", dir .. "/fake.gguf.part", dir .. "/fake.gguf.old"
  local function content(path)
    return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path)[1] or "(missing)"
  end
  local function files()
    return ("dest=%s part=%s old=%s"):format(content(dest), content(part), content(old))
  end
  check("ai.install exists", type(ai.install) == "function")
  local function install(from, to)
    if not ai.install then
      return "ai.install missing"
    end
    return ai.install(from, to)
  end
  vim.fn.writefile({ "old" }, dest)
  vim.fn.writefile({ "new" }, part)
  local err, warn = install(part, dest)
  check("install replaces an existing model", err == nil and content(dest) == "new" and vim.fn.filereadable(part) == 0, err or files())
  check("install leaves no .old behind", warn == nil and vim.fn.filereadable(old) == 0, warn or files())
  vim.fn.delete(dest)
  vim.fn.writefile({ "fresh" }, part)
  err = install(part, dest)
  check("install with nothing to replace", err == nil and content(dest) == "fresh", err or files())
  -- No download at all (the .part is gone): an error, and the old model untouched.
  err = install(part, dest)
  check("install without a download reports it", type(err) == "string" and err:find(part, 1, true) ~= nil, err)
  check("install without a download keeps the old model", content(dest) == "fresh" and vim.fn.filereadable(old) == 0, files())
  if win then
    -- An open file can be neither renamed nor removed on Windows. The old model held
    -- (something reading it): install must say so and leave both files as they are.
    vim.fn.writefile({ "newer" }, part)
    local hold = io.open(dest, "r")
    err = install(part, dest)
    check("install reports a file it can't replace", type(err) == "string" and err:find(dest, 1, true) ~= nil, err)
    check("install keeps the old file it can't replace", content(dest) == "fresh" and content(part) == "newer" and vim.fn.filereadable(old) == 0, files())
    hold:close()
    -- The download held (a virus scanner reading the fresh file): the old model has
    -- stepped aside by then and must come back.
    hold = io.open(part, "r")
    err = install(part, dest)
    check("install reports a download it can't move", type(err) == "string" and err:find(part, 1, true) ~= nil, err)
    check("install brings the old model back", content(dest) == "fresh" and content(part) == "newer" and vim.fn.filereadable(old) == 0, files())
    hold:close()
    -- A hold that lets go within a second (a scan): install waits it out. A child
    -- Neovim holds the download, drops a marker so the timing is known, then lets go.
    local script, marker = dir .. "/hold.lua", dir .. "/held"
    vim.fn.writefile({ ("local f = io.open(%q, 'r') vim.fn.writefile({ 'x' }, %q) vim.wait(800) f:close() vim.cmd('qa!')"):format(part, marker) }, script)
    local holder = vim.system({ "nvim", "--headless", "-u", "NONE", "-c", "luafile " .. script }, { text = true })
    local held = vim.wait(5000, function()
      return vim.fn.filereadable(marker) == 1
    end, 20)
    local t0 = vim.uv.hrtime()
    err = install(part, dest)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    check("install waits out a brief hold", held and err == nil and content(dest) == "newer" and vim.fn.filereadable(part) == 0 and ms >= 200,
      ("held=%s %s in %.0f ms"):format(tostring(held), err or files(), ms))
    holder:wait(5000)
  end

  -- The whole pull path: resolve stubbed, curl reading a file:// URL, into this folder.
  local keep_dir = a.llamacpp.models_dir
  a.llamacpp.models_dir = dir
  local src = dir .. "/src.gguf"
  vim.fn.writefile({ "pulled" }, src)
  local resolve = ai.resolve
  ai.resolve = function(_, cb)
    cb(nil, { { url = "file:///" .. src, file = "fake.gguf" } })
  end
  local notes, restore = capture_notify()
  local r = collect(20000, function(done)
    ai.pull("stub", done)
  end)
  check("pull replaces an existing model", r and r[1] == nil and r[2] == "fake.gguf" and content(dest) == "pulled", r and (r[1] or r[2]) or "timeout")
  check("pull says the model is ready", noted(notes, "Model ready"), vim.inspect(notes))
  check("pull leaves no .part or .old behind", vim.fn.filereadable(part) == 0 and vim.fn.filereadable(old) == 0, files())
  if win then
    -- The old model held: the real error, no "ready", the old model kept, the
    -- download dropped.
    restore()
    notes, restore = capture_notify()
    local hold = io.open(dest, "r")
    r = collect(20000, function(done)
      ai.pull("stub", done)
    end)
    check("pull reports the real error", r and type(r[1]) == "string" and r[1]:find(dest, 1, true) ~= nil and r[1]:find("denied", 1, true) ~= nil, r and (r[1] or r[2]) or "timeout")
    check("pull does not say ready when it failed", not noted(notes, "Model ready") and noted(notes, "Couldn't"), vim.inspect(notes))
    check("pull keeps the old model and drops the download", vim.fn.filereadable(part) == 0 and content(dest) == "pulled" and vim.fn.filereadable(old) == 0, files())
    hold:close()
    -- The download held the moment curl is done with it: the old model stays, and the
    -- message says where the download is, since a held file cannot be dropped either.
    restore()
    notes, restore = capture_notify()
    local real_system = vim.system
    local hold2
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == "curl" and on_exit then
        return real_system(cmd, opts, function(res)
          hold2 = io.open(part, "r")
          on_exit(res)
        end)
      end
      return real_system(cmd, opts, on_exit)
    end
    r = collect(20000, function(done)
      ai.pull("stub", done)
    end)
    vim.system = real_system
    check("pull reports a download it can't move", r and type(r[1]) == "string" and r[1]:find(part, 1, true) ~= nil, r and (r[1] or r[2]) or "timeout")
    check("pull keeps the old model when the download is held", content(dest) == "pulled" and vim.fn.filereadable(old) == 0 and not noted(notes, "Model ready"), files())
    check("pull names the download it couldn't drop", r and type(r[1]) == "string" and r[1]:find("still at", 1, true) ~= nil and vim.fn.filereadable(part) == 1, r and tostring(r[1]) or "timeout")
    if hold2 then
      hold2:close()
    end
  end
  restore()
  ai.resolve = resolve
  a.llamacpp.models_dir = keep_dir
  vim.fn.delete(dir, "rf")
end

---------------------------------------------------------------------------
-- net: resolve, pull, Ask and minuet against the real network and models folder
---------------------------------------------------------------------------
if groups.net then
  local list
  ai.models(function(err, l)
    list = l or { err = err }
  end)
  vim.wait(60000, function()
    return list ~= nil
  end, 200)
  check("router lists models", list and list[1] and list[1].id:find("qwen") ~= nil, list and (list.err or vim.inspect(vim.tbl_map(function(m)
    return m.id
  end, list))))
  local res
  ai.resolve("Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M", function(e, p)
    res = p or e
  end)
  vim.wait(20000, function()
    return res ~= nil
  end, 100)
  check("resolve repo:quant", type(res) == "table" and res[1].file == "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf", type(res) == "table" and res[1].url or res)
  local res7
  ai.resolve("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF:q4_k_m", function(e, p)
    res7 = p or e
  end)
  vim.wait(20000, function()
    return res7 ~= nil
  end, 100)
  check("resolve prefers single file", type(res7) == "table" and #res7 == 1 and res7[1].file == "qwen2.5-coder-7b-instruct-q4_k_m.gguf", type(res7) == "table" and #res7 or res7)
  -- Ask with no written answer -> the model
  local t0 = vim.uv.now()
  require("nvs.ask").answer("what is the capital of france")
  vim.wait(240000, function()
    return vim.bo.filetype == "markdown" and vim.api.nvim_win_get_config(0).relative == "editor"
  end, 250)
  local body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  check("ask falls back to the model", body:find("Answer from qwen") ~= nil, ("%.1fs: %s"):format((vim.uv.now() - t0) / 1000, body:sub(1, 200)))
  check("model answer mentions Paris", body:lower():find("paris") ~= nil)
  vim.cmd("close")
  -- download a small model through :NvsModel pull
  local pulled
  ai.pull("Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF:q2_k", function(e, f)
    pulled = f or ("ERR " .. tostring(e))
  end)
  vim.wait(300000, function()
    return pulled ~= nil
  end, 250)
  check("pull downloads a model", pulled == "qwen2.5-coder-0.5b-instruct-q2_k.gguf", pulled)
  local list2
  ai.models(function(err, l)
    list2 = l or { err = err }
  end)
  vim.wait(60000, function()
    return list2 ~= nil
  end, 200)
  local ids = vim.tbl_map(function(m)
    return m.id
  end, list2)
  check("restarted server lists the new model", vim.tbl_contains(ids, "qwen2.5-coder-0.5b-instruct-q2_k"), vim.inspect(ids))
  check("fim template for qwen", ai.fim_template("qwen2.5-coder-1.5b"):find("<|fim_prefix|>", 1, true) ~= nil)
  -- minuet picks up the llama.cpp config
  vim.api.nvim_exec_autocmds("InsertEnter", {})
  vim.wait(2000)
  local okm, minuet = pcall(require, "minuet")
  local fimcfg = okm and minuet.config and minuet.config.provider_options.openai_fim_compatible
  check("minuet uses llama-server", fimcfg and fimcfg.end_point == "http://127.0.0.1:8012/v1/completions", fimcfg and fimcfg.end_point)
  check("minuet FIM prompt", fimcfg and fimcfg.template and fimcfg.template.prompt("a", "b") == "<|fim_prefix|>a<|fim_suffix|>b<|fim_middle|>", fimcfg and fimcfg.template and fimcfg.template.prompt("a", "b"))
end

finish(0)
