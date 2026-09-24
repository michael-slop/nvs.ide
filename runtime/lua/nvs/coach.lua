-- The coach: when someone does something the VS Code way, show the Vim way.
-- Each hint has an id, and the frequency setting caps how often it repeats.
local state = require("nvs.state")

local M = {}
local seen = {}
local limits = { always = math.huge, three = 3, once = 1, off = 0 }

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

return M
