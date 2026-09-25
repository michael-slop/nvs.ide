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

function M.load()
  local f = io.open(path(), "r")
  if f then
    local ok, decoded = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(decoded) == "table" then
      -- Settings from before the llama.cpp backend: keep using Ollama as configured.
      local old = decoded.ollama
      if type(old) == "table" and not decoded.ai then
        decoded.ai = { enabled = old.enabled, backend = "ollama", chat_model = old.chat_model or "",
          complete_model = old.complete_model or "", ollama = { url = old.url } }
      end
      decoded.ollama = nil
      M.data = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), decoded)
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
