-- Persistent nvs.ide state: the stage, coach frequency and local AI settings.
-- Stored as JSON in stdpath("data") so it survives restarts and config updates.
local M = {}

M.defaults = {
  stage = 2,
  welcomed = false,
  coach = "three", -- "always" | "three" | "once" | "off"
  ai = {
    enabled = false,
    backend = "llamacpp", -- "llamacpp" (built in) | "ollama" | "openai"
    chat_model = "", -- empty: the first model the server has
    complete_model = "", -- empty: same as chat_model
    ghost_text = true,
    llamacpp = {
      server = "llama-server", -- name on PATH, or a full path
      models_dir = "", -- empty: stdpath("data")/models
      port = 8012,
      models_max = 2, -- models kept loaded at once
      gpu_layers = "auto",
      extra_args = {},
    },
    ollama = { url = "http://localhost:11434" },
    openai = { url = "http://localhost:1234", api_key_env = "" },
  },
}

M.data = vim.deepcopy(M.defaults)

local function path()
  return vim.fn.stdpath("data") .. "/nvs-ide.json"
end

---------------------------------------------------------------------------
-- Validation. A hand-edited file ("stage":"2", "port":"abc") used to break every
-- start with no message pointing at it. Each key is checked against M.defaults:
-- a value that converts safely is converted, anything else becomes the default,
-- and one warning names the file and the keys touched.
---------------------------------------------------------------------------

-- A number from a saved value: numbers pass, decimal strings ("2", "8012") convert.
-- tonumber() alone would also take "0x10", "1e3" and "inf", which nobody means here.
local function to_number(v)
  if type(v) == "string" and v:match("^%s*[-+]?%d+%.?%d*%s*$") then
    v = tonumber(v)
  end
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
    return nil
  end
  return v
end

-- A whole number within [min, max]; nil when the value cannot be one.
local function integer(v, min, max)
  local n = to_number(v)
  if not n then
    return nil
  end
  n = math.floor(n)
  if (min and n < min) or (max and n > max) then
    return nil
  end
  return n
end

local function one_of(v, values)
  if type(v) == "string" and vim.tbl_contains(values, v) then
    return v
  end
  return nil
end

-- Keys that need more than "the same type as the default", by dotted path. Each takes
-- the saved value and returns the value to keep, or nil when the default must stand in.
local rules = {
  stage = function(v)
    -- Out of range is clamped, not reset: 7 means "as far as it goes", 0 means the start.
    local n = integer(v)
    return n and math.max(1, math.min(4, n)) or nil
  end,
  coach = function(v)
    return one_of(v, { "always", "three", "once", "off" })
  end,
  ["ai.backend"] = function(v)
    return one_of(v, { "llamacpp", "ollama", "openai" })
  end,
  ["ai.llamacpp.port"] = function(v)
    return integer(v, 1, 65535)
  end,
  ["ai.llamacpp.models_max"] = function(v)
    return integer(v, 1)
  end,
  ["ai.llamacpp.gpu_layers"] = function(v)
    -- "auto" or a layer count; ai.lua hands llama-server tostring() of it either way.
    if type(v) == "string" then
      return v
    end
    return integer(v)
  end,
  ["ai.llamacpp.extra_args"] = function(v)
    -- A list of strings: ai.lua appends it to the llama-server command line as is.
    if type(v) ~= "table" or not vim.islist(v) then
      return nil
    end
    for _, a in ipairs(v) do
      if type(a) ~= "string" then
        return nil
      end
    end
    return v
  end,
}

-- The default rule: the saved value must have the default's type. Numbers accept decimal
-- strings and booleans accept "true"/"false", since a hand edit easily quotes a value.
local function same_type(v, default)
  local t = type(default)
  if type(v) == t then
    return v
  end
  if t == "number" then
    return to_number(v)
  end
  if t == "boolean" and (v == "true" or v == "false") then
    return v == "true"
  end
  return nil
end

-- Walk the defaults and make every key of `data` usable in place. The dotted names of
-- the keys that changed go into `fixed`. Keys the defaults do not know are left alone:
-- nothing reads them, and a newer version's setting should survive a downgrade.
local function repair(defaults, data, prefix, fixed)
  for k, default in pairs(defaults) do
    local name = prefix .. k
    local v = data[k]
    local rule = rules[name]
    local good
    if rule then
      good = rule(v)
    elseif type(default) == "table" then
      if type(v) == "table" then
        repair(default, v, name .. ".", fixed)
        good = v
      end
    else
      good = same_type(v, default)
    end
    if good == nil then
      good = vim.deepcopy(default)
    end
    if v ~= nil and good ~= v then
      table.insert(fixed, name)
    end
    data[k] = good
  end
end

-- The check load() applies to one key, for code that takes a value from the user
-- (:NvsAI port): the value to keep, or nil when nothing safe can be made of it, so
-- what the command accepts and what the file may hold stay one definition.
function M.check(name, v)
  local rule = rules[name]
  if rule then
    return rule(v)
  end
  local default = M.defaults
  for part in name:gmatch("[^.]+") do
    if type(default) ~= "table" then
      return nil
    end
    default = default[part]
  end
  if default == nil or type(default) == "table" then
    return nil
  end
  return same_type(v, default)
end

-- Warn once per file content: load() runs from config/options.lua and again from
-- nvs.setup(), and the same broken file must not warn twice. Keyed on the text read,
-- not on the message, so a different problem that repairs the same keys still warns.
-- Shown after startup so it reaches the notifier instead of scrolling past under the
-- startup messages.
local warned = {}

local function warn(text, msg)
  if warned[text] then
    return
  end
  warned[text] = true
  local function show()
    vim.notify(msg, vim.log.levels.WARN, { title = "nvs.ide" })
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(show)
  else
    vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = vim.schedule_wrap(show) })
  end
end

function M.load()
  local f = io.open(path(), "r")
  if f then
    local text = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if ok and type(decoded) == "table" then
      -- Settings from before the llama.cpp backend: keep using Ollama as configured.
      local old = decoded.ollama
      if type(old) == "table" and not decoded.ai then
        decoded.ai = { enabled = old.enabled, backend = "ollama", chat_model = old.chat_model or "",
          complete_model = old.complete_model or "", ollama = { url = old.url } }
      end
      decoded.ollama = nil
      M.data = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), decoded)
      local fixed = {}
      repair(M.defaults, M.data, "", fixed)
      if #fixed > 0 then
        table.sort(fixed)
        warn(text, ("Repaired settings in %s: %s. Values were converted where that was safe and reset to the default otherwise."):format(
          path(), table.concat(fixed, ", ")))
      end
    else
      warn(text, ("%s is not valid JSON, so the defaults are in use. Fix the file or delete it."):format(path()))
    end
  end
  vim.g.nvs_stage = M.data.stage
  vim.g.nvs_ai = M.data.ai.enabled
  return M.data
end

function M.save()
  vim.fn.mkdir(vim.fn.stdpath("data"), "p")
  local f = assert(io.open(path(), "w"))
  f:write(vim.json.encode(M.data))
  f:close()
  vim.g.nvs_stage = M.data.stage
  vim.g.nvs_ai = M.data.ai.enabled
end

return M
