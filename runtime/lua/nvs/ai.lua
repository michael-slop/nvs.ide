-- Local AI for nvs.ide: Ask's fallback and ghost-text completion.
--
-- Three backends, all spoken to through the OpenAI-compatible API:
--   llamacpp  nvs.ide runs llama.cpp's llama-server itself, in router mode over a
--             folder of GGUF files: any model you download, loaded on demand.
--             No Ollama needed. This is the default.
--   ollama    an Ollama server you run (default http://localhost:11434)
--   openai    any other OpenAI-compatible server (LM Studio, vLLM, llamafile...)
--
-- Everything talks to 127.0.0.1 unless you point a URL elsewhere. For a model on
-- another machine, forward its port over SSH and keep the local address.
local state = require("nvs.state")

local M = {}

local server -- vim.SystemObj for the managed llama-server
local ready = false
local waiting = {} -- callbacks queued while the server starts

local function cfg()
  return state.data.ai
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "nvs.ide · local AI" })
end

function M.models_dir()
  local dir = cfg().llamacpp.models_dir
  if not dir or dir == "" then
    dir = vim.fn.stdpath("data") .. "/models"
  end
  return vim.fs.normalize(dir)
end

function M.base_url()
  local c = cfg()
  if c.backend == "llamacpp" then
    return ("http://127.0.0.1:%d"):format(c.llamacpp.port)
  end
  return (c[c.backend].url):gsub("/+$", "")
end

local function headers()
  local h = { "-H", "Content-Type: application/json" }
  local env = cfg().backend == "openai" and cfg().openai.api_key_env or ""
  if env ~= "" and vim.env[env] then
    vim.list_extend(h, { "-H", "Authorization: Bearer " .. vim.env[env] })
  end
  return h
end

-- curl wrapper: request(method, path, body_table_or_nil, timeout_s, cb(err, decoded))
local function request(method, path, body, timeout, cb)
  local cmd = { "curl", "-s", "-m", tostring(timeout), "-X", method, M.base_url() .. path }
  vim.list_extend(cmd, headers())
  local opts = { text = true }
  if body then
    vim.list_extend(cmd, { "--data-binary", "@-" })
    opts.stdin = vim.json.encode(body)
  end
  vim.system(cmd, opts, vim.schedule_wrap(function(res)
    if res.code ~= 0 or res.stdout == "" then
      return cb(("Can't reach %s (%s)."):format(M.base_url(), cfg().backend))
    end
    local ok, decoded = pcall(vim.json.decode, res.stdout)
    if not ok then
      return cb("The server sent something that isn't JSON: " .. res.stdout:sub(1, 200))
    end
    if type(decoded) == "table" and decoded.error then
      local e = decoded.error
      return cb(type(e) == "table" and (e.message or vim.inspect(e)) or tostring(e))
    end
    cb(nil, decoded)
  end))
end

---------------------------------------------------------------------------
-- Managed llama-server
---------------------------------------------------------------------------

function M.server_path()
  local s = cfg().llamacpp.server
  local path = vim.fn.exepath(s)
  if path == "" and vim.uv.fs_stat(s) then
    path = s
  end
  return path ~= "" and path or nil
end

local function flush(err)
  local q = waiting
  waiting = {}
  for _, cb in ipairs(q) do
    cb(err)
  end
end

local function wait_healthy(deadline)
  vim.system({ "curl", "-s", "-m", "1", M.base_url() .. "/health" }, { text = true }, vim.schedule_wrap(function(res)
    if res.code == 0 and res.stdout:find('"ok"') then
      ready = true
      return flush(nil)
    end
    if not server or vim.uv.now() > deadline then
      return flush("llama-server didn't start. Its log is at " .. vim.fn.stdpath("log") .. "/nvs-llama-server.log")
    end
    vim.defer_fn(function()
      wait_healthy(deadline)
    end, 300)
  end))
end

-- Start llama-server in router mode if it isn't running. cb(err)
function M.ensure(cb)
  cb = cb or function() end
  if cfg().backend ~= "llamacpp" then
    return cb(nil)
  end
  if server and ready then
    return cb(nil)
  end
  table.insert(waiting, cb)
  if server then
    return -- already starting
  end
  local exe = M.server_path()
  if not exe then
    return flush("llama-server isn't installed. Get llama.cpp (winget install llama.cpp, scoop install llama.cpp, or brew install llama.cpp), or set its path with :NvsAI server <path>.")
  end
  vim.fn.mkdir(M.models_dir(), "p")
  local l = cfg().llamacpp
  local args = {
    exe, "--models-dir", M.models_dir(), "--models-max", tostring(l.models_max),
    "--host", "127.0.0.1", "--port", tostring(l.port), "--no-webui", "-ngl", tostring(l.gpu_layers),
  }
  vim.list_extend(args, l.extra_args or {})
  local log = assert(io.open(vim.fn.stdpath("log") .. "/nvs-llama-server.log", "w"))
  local function sink(_, data)
    if data then
      log:write(data)
      log:flush()
    end
  end
  ready = false
  server = vim.system(args, { stdout = sink, stderr = sink }, function()
    server, ready = nil, false
    pcall(log.close, log)
  end)
  wait_healthy(vim.uv.now() + 60000)
end

function M.stop()
  if server then
    server:kill(15)
    server, ready = nil, false
  end
end

function M.restart(cb)
  M.stop()
  vim.defer_fn(function()
    M.ensure(cb)
  end, 500)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("nvs_ai", { clear = true }),
  callback = M.stop,
})

---------------------------------------------------------------------------
-- Models
---------------------------------------------------------------------------

-- cb(err, { { id=, status= }, ... })
function M.models(cb)
  M.ensure(function(err)
    if err then
      return cb(err)
    end
    request("GET", "/v1/models", nil, 10, function(e, d)
      if e then
        return cb(e)
      end
      local out = {}
      for _, m in ipairs(d.data or {}) do
        table.insert(out, { id = m.id, status = type(m.status) == "table" and m.status.value or nil })
      end
      cb(nil, out)
    end)
  end)
end

-- The model to use for a role ("chat" or "complete"); falls back to the first model the server has.
function M.pick(role, cb)
  local c = cfg()
  local want = role == "complete" and (c.complete_model ~= "" and c.complete_model or c.chat_model) or c.chat_model
  if want and want ~= "" then
    return cb(nil, want)
  end
  M.models(function(err, list)
    if err then
      return cb(err)
    end
    if #list == 0 then
      return cb("No models yet. Download one with :NvsModel pull Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M")
    end
    cb(nil, list[1].id)
  end)
end

-- Resolve "owner/repo[:quant]" (or a direct https URL to a .gguf) to download URLs.
function M.resolve(spec, cb)
  if spec:match("^https?://") then
    local file = spec:match("([^/?]+%.gguf)")
    if not file then
      return cb("That link doesn't point at a .gguf file.")
    end
    return cb(nil, { { url = spec, file = file } })
  end
  local repo, quant = spec:match("^([^:]+):?(.*)$")
  vim.system({ "curl", "-s", "-m", "20", "https://huggingface.co/api/models/" .. repo }, { text = true }, vim.schedule_wrap(function(res)
    local ok, d = pcall(vim.json.decode, res.stdout or "")
    if res.code ~= 0 or not ok or type(d) ~= "table" or not d.siblings then
      return cb("Couldn't find " .. repo .. " on Hugging Face.")
    end
    local files, split = {}, {}
    quant = quant ~= "" and quant:lower() or "q4_k_m"
    for _, s in ipairs(d.siblings) do
      local f = s.rfilename
      local lf = f:lower()
      if lf:match("%.gguf$") and not lf:find("mmproj") and lf:find(quant, 1, true) then
        table.insert(lf:find("%-of%-") and split or files, f)
      end
    end
    if #files == 0 then
      files = split -- only a multi-part upload exists; llama.cpp loads it from the first part
    end
    if #files == 0 then
      return cb(("No %s GGUF file in %s."):format(quant, repo))
    end
    table.sort(files)
    local out = {}
    for _, f in ipairs(#split > 0 and files == split and files or { files[1] }) do
      table.insert(out, { url = ("https://huggingface.co/%s/resolve/main/%s"):format(repo, f), file = vim.fs.basename(f) })
    end
    cb(nil, out)
  end))
end

-- Download a model into the models folder, then restart the server so it shows up.
function M.pull(spec, cb)
  cb = cb or function() end
  if cfg().backend ~= "llamacpp" then
    return cb("Downloading models is for the built-in llama.cpp backend. For Ollama, use ollama pull.")
  end
  M.resolve(spec, function(err, parts)
    if err then
      notify(err, vim.log.levels.WARN)
      return cb(err)
    end
    local dir = M.models_dir()
    vim.fn.mkdir(dir, "p")
    notify(("Downloading %s to %s…"):format(table.concat(vim.tbl_map(function(p) return p.file end, parts), ", "), dir))
    local i = 0
    local function next_part()
      i = i + 1
      local p = parts[i]
      if not p then
        notify("Model ready: " .. parts[1].file:gsub("%.gguf$", ""))
        if server then
          M.restart(function() cb(nil, parts[1].file) end)
        else
          cb(nil, parts[1].file)
        end
        return
      end
      local dest = dir .. "/" .. p.file
      vim.system({ "curl", "-sfL", "-o", dest .. ".part", p.url }, {}, vim.schedule_wrap(function(res)
        if res.code ~= 0 then
          os.remove(dest .. ".part")
          local e = "Download failed: " .. p.url
          notify(e, vim.log.levels.WARN)
          return cb(e)
        end
        os.rename(dest .. ".part", dest)
        next_part()
      end))
    end
    next_part()
  end)
end

---------------------------------------------------------------------------
-- Chat
---------------------------------------------------------------------------

-- chat({ {role=, content=}, ... }, function(err, text, model) end)
function M.chat(messages, cb)
  M.ensure(function(err)
    if err then
      return cb(err)
    end
    M.pick("chat", function(e, model)
      if e then
        return cb(e)
      end
      request("POST", "/v1/chat/completions", { model = model, messages = messages, stream = false }, 180, function(e2, d)
        if e2 then
          return cb(e2)
        end
        local choice = d.choices and d.choices[1]
        cb(nil, choice and choice.message and choice.message.content or "", model)
      end)
    end)
  end)
end

---------------------------------------------------------------------------
-- Fill-in-the-middle prompts for ghost text on llama.cpp. Ollama applies the
-- model's own template server-side, so it only needs prefix and suffix.
---------------------------------------------------------------------------

local FIM = {
  { "qwen", "<|fim_prefix|>%s<|fim_suffix|>%s<|fim_middle|>" },
  { "deepseek", "<｜fim▁begin｜>%s<｜fim▁hole｜>%s<｜fim▁end｜>" },
  { "codellama", "<PRE> %s <SUF>%s <MID>" },
  { "starcoder", "<fim_prefix>%s<fim_suffix>%s<fim_middle>" },
  { "codegemma", "<|fim_prefix|>%s<|fim_suffix|>%s<|fim_middle|>" },
}

function M.fim_template(model)
  local m = (model or ""):lower()
  for _, f in ipairs(FIM) do
    if m:find(f[1], 1, true) then
      return f[2]
    end
  end
  return FIM[1][2]
end

---------------------------------------------------------------------------
-- :NvsAI and :NvsModel
---------------------------------------------------------------------------

function M.status()
  local c = cfg()
  local lines = {
    ("Local AI: %s   Backend: %s   Address: %s"):format(c.enabled and "on" or "off", c.backend, M.base_url()),
    ("Ask model: %s   Completion model: %s"):format(c.chat_model ~= "" and c.chat_model or "(first available)", c.complete_model ~= "" and c.complete_model or "(same as Ask)"),
  }
  if c.backend == "llamacpp" then
    table.insert(lines, ("llama-server: %s   Models folder: %s"):format(M.server_path() or "not found", M.models_dir()))
  end
  M.models(function(err, list)
    if err then
      table.insert(lines, err)
    else
      local names = vim.tbl_map(function(m) return m.id .. (m.status and (" [" .. m.status .. "]") or "") end, list)
      table.insert(lines, "Models: " .. (#names > 0 and table.concat(names, ", ") or "none yet (:NvsModel pull <repo:quant>)"))
    end
    notify(table.concat(lines, "\n"))
  end)
end

function M.command(args)
  local sub, rest = args:match("^(%S*)%s*(.-)$")
  local c = cfg()
  if sub == "on" or sub == "off" then
    c.enabled = sub == "on"
    state.save()
    notify(("Local AI %s (%s). Ghost text takes effect after a restart."):format(c.enabled and "on" or "off", c.backend))
  elseif sub == "backend" and vim.tbl_contains({ "llamacpp", "ollama", "openai" }, rest) then
    M.stop()
    c.backend = rest
    c.chat_model, c.complete_model = "", ""
    state.save()
    notify("Backend: " .. rest .. " at " .. M.base_url())
  elseif sub == "url" and rest ~= "" then
    if c.backend == "llamacpp" then
      return notify("The built-in backend always listens on 127.0.0.1. Change its port with :NvsAI port <n>.", vim.log.levels.WARN)
    end
    c[c.backend].url = rest
    state.save()
    notify(c.backend .. " address: " .. rest)
  elseif sub == "port" and tonumber(rest) then
    c.llamacpp.port = tonumber(rest)
    state.save()
    M.stop()
    notify("llama-server port: " .. rest)
  elseif sub == "server" and rest ~= "" then
    c.llamacpp.server = rest
    state.save()
    M.stop()
    notify("llama-server: " .. (M.server_path() or (rest .. " (not found)")))
  elseif sub == "stop" then
    M.stop()
    notify("llama-server stopped")
  else
    M.status()
  end
end

function M.model_command(args)
  local sub, rest = args:match("^(%S*)%s*(.-)$")
  if sub == "pull" and rest ~= "" then
    return M.pull(rest)
  end
  if sub == "folder" then
    vim.fn.mkdir(M.models_dir(), "p")
    return vim.ui.open(M.models_dir())
  end
  M.models(function(err, list)
    if err then
      return notify(err, vim.log.levels.WARN)
    end
    local items = vim.tbl_map(function(m) return { id = m.id, status = m.status } end, list)
    if cfg().backend == "llamacpp" then
      table.insert(items, { id = "Download a model from Hugging Face…", pull = true })
    end
    vim.ui.select(items, {
      prompt = "Local model",
      format_item = function(m)
        return m.id .. (m.status and ("  [" .. m.status .. "]") or "")
      end,
    }, function(m)
      if not m then
        return
      end
      if m.pull then
        return vim.ui.input({ prompt = "Hugging Face repo[:quant] ", default = "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M" }, function(spec)
          if spec and spec ~= "" then
            M.pull(spec)
          end
        end)
      end
      vim.ui.select({ "Ask and completion", "Ask only", "Completion only" }, { prompt = "Use " .. m.id .. " for" }, function(role)
        if not role then
          return
        end
        local c = cfg()
        if role ~= "Completion only" then
          c.chat_model = m.id
        end
        if role ~= "Ask only" then
          c.complete_model = m.id
        end
        state.save()
        notify(("Using %s for %s."):format(m.id, role:lower()))
      end)
    end)
  end)
end

return M
