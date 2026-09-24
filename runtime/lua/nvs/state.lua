-- Persistent nvs.ide state: the stage, coach frequency and local AI settings.
-- Stored as JSON in stdpath("data") so it survives restarts and config updates.
local M = {}

M.defaults = {
  stage = 2,
  welcomed = false,
  coach = "three", -- "always" | "three" | "once" | "off"
  ollama = {
    enabled = false,
    url = "http://localhost:11434",
    chat_model = "qwen2.5-coder:7b",
    complete_model = "qwen2.5-coder:1.5b",
    ghost_text = true,
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
      M.data = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), decoded)
    end
  end
  vim.g.nvs_stage = M.data.stage
  vim.g.nvs_ollama = M.data.ollama.enabled
  return M.data
end

function M.save()
  vim.fn.mkdir(vim.fn.stdpath("data"), "p")
  local f = assert(io.open(path(), "w"))
  f:write(vim.json.encode(M.data))
  f:close()
  vim.g.nvs_stage = M.data.stage
  vim.g.nvs_ollama = M.data.ollama.enabled
end

return M
