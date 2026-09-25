-- The coach: when someone does something the VS Code way, show the Vim way.
-- Each hint has an id, and the frequency setting caps how often it repeats.
local state = require("nvs.state")

local M = {}
local seen = {}
local limits = { always = math.huge, three = 3, once = 1, off = 0 }

-- In the order :NvsCoach completes them.
M.frequencies = { "always", "three", "once", "off" }
local described = { always = "every time", three = "up to three times each", once = "once each", off = "never" }

function M.hint(id, text)
  if state.data.stage >= 4 then
    return
  end
  seen[id] = (seen[id] or 0) + 1
  if seen[id] > (limits[state.data.coach] or 3) then
    return
  end
  vim.notify(text, vim.log.levels.INFO, { title = "nvs.ide · the Vim way", id = "nvs-coach-" .. id })
end

-- Arrow keys: count presses in a row and suggest counts with j/k.
local run, last = 0, 0
function M.arrow(key)
  local now = vim.uv.now()
  run = (now - last < 1500) and run + 1 or 1
  last = now
  if run >= 6 then
    run = 0
    local vim_key = ({ Up = "k", Down = "j", Left = "h", Right = "l" })[key]
    local msg = state.data.stage == 1
        and ("Lots of arrow presses. At Stage 2 you can press Esc, then 6" .. vim_key .. " moves six at once.")
      or ("Lots of arrow presses. In Normal mode, 6" .. vim_key .. " moves six at once. The relative numbers tell you the count.")
    M.hint("arrows", msg)
  end
end

---------------------------------------------------------------------------
-- :NvsCoach: the hint frequency and the ghost-text flag, without editing the JSON.
---------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "nvs.ide" })
end

local function frequency_line()
  local c = state.data.coach
  local line = ("Coach hints: %s (shown %s)."):format(c, described[c] or described.three)
  if state.data.stage >= 4 then
    -- M.hint shows nothing at Stage 4: pure Neovim adds no VS Code keys to coach.
    line = line .. " Stage 4 shows none; the setting applies at Stages 1 to 3."
  end
  return line
end

-- Ghost text is read by a plugin spec (plugins/nvs.lua) when Neovim starts, so like
-- :NvsAI on a change only shows after a restart. That spec also skips the openai
-- backend: plain OpenAI-compatible servers rarely do fill-in-the-middle.
local function ghost_line()
  local a = state.data.ai
  local line = ("Ghost text: %s."):format(a.ghost_text and "on" or "off")
  if a.ghost_text and not a.enabled then
    line = line .. " It needs local AI, which is off (:NvsAI on)."
  end
  if a.ghost_text and a.backend == "openai" then
    line = line .. " It does not load with the openai backend (:NvsAI backend llamacpp or ollama)."
  end
  return line
end

local function changed()
  state.save()
  vim.api.nvim_exec_autocmds("User", { pattern = "NvsStateChanged", modeline = false })
end

function M.command(args)
  local sub, rest = args:match("^(%S*)%s*(.-)$")
  if sub == "" then
    return notify(frequency_line() .. "\n" .. ghost_line())
  end
  if vim.tbl_contains(M.frequencies, sub) then
    state.data.coach = sub
    -- A new frequency starts the counts over, so "off" and then "three" shows hints again.
    seen = {}
    changed()
    return notify(frequency_line())
  end
  if sub == "ghost" and (rest == "on" or rest == "off") then
    state.data.ai.ghost_text = rest == "on"
    changed()
    return notify(ghost_line() .. " Takes effect after a restart.")
  end
  notify("Usage: :NvsCoach [always|three|once|off]  or  :NvsCoach ghost on|off", vim.log.levels.WARN)
end

return M
