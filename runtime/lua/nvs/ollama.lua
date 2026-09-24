-- Talks to a local Ollama server. Everything goes to the configured URL only;
-- if Ollama runs on another machine, forward port 11434 over SSH and keep the default.
local state = require("nvs.state")

local M = {}

local function url(p)
  return state.data.ollama.url:gsub("/+$", "") .. p
end

-- chat({ {role=, content=}, ... }, function(err, text) end)
function M.chat(messages, cb)
  local body = vim.json.encode({ model = state.data.ollama.chat_model, messages = messages, stream = false })
  vim.system(
    { "curl", "-s", "-m", "120", "-X", "POST", url("/api/chat"), "-H", "Content-Type: application/json", "--data-binary", "@-" },
    { stdin = body, text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 or res.stdout == "" then
        return cb(("Ollama isn't reachable at %s. Is `ollama serve` running, or the SSH tunnel up?"):format(state.data.ollama.url))
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout)
      if not ok then
        return cb("Ollama sent something that isn't JSON: " .. res.stdout:sub(1, 200))
      end
      if decoded.error then
        return cb("Ollama: " .. decoded.error)
      end
      cb(nil, decoded.message and decoded.message.content or "")
    end)
  )
end

function M.status(cb)
  vim.system({ "curl", "-s", "-m", "5", url("/api/tags") }, { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 or res.stdout == "" then
      return cb(false, {})
    end
    local ok, decoded = pcall(vim.json.decode, res.stdout)
    local names = {}
    for _, m in ipairs(ok and decoded.models or {}) do
      table.insert(names, m.name)
    end
    cb(true, names)
  end))
end

-- :NvsOllama on | off | status | model <name> | url <url>
function M.command(args)
  local sub, rest = args:match("^(%S*)%s*(.-)$")
  local o = state.data.ollama
  if sub == "on" or sub == "off" then
    o.enabled = sub == "on"
    state.save()
    vim.notify(("Local AI %s. Ghost-text completion takes effect after a restart."):format(o.enabled and "on" or "off"), vim.log.levels.INFO, { title = "nvs.ide" })
  elseif sub == "model" and rest ~= "" then
    o.chat_model = rest
    state.save()
    vim.notify("Ask will use " .. rest, vim.log.levels.INFO, { title = "nvs.ide" })
  elseif sub == "url" and rest ~= "" then
    o.url = rest
    state.save()
    vim.notify("Ollama address set to " .. rest, vim.log.levels.INFO, { title = "nvs.ide" })
  else
    M.status(function(up, models)
      local lines = {
        ("Local AI: %s"):format(o.enabled and "on" or "off"),
        ("Address: %s (%s)"):format(o.url, up and "reachable" or "not reachable"),
        ("Ask model: %s   Completion model: %s"):format(o.chat_model, o.complete_model),
      }
      if up then
        table.insert(lines, "Installed models: " .. (#models > 0 and table.concat(models, ", ") or "none"))
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "nvs.ide · :NvsOllama" })
    end)
  end
end

return M
