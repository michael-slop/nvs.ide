-- The four-stage ramp from VS Code to Neovim.
--   1 VS Code keys           always typing; Esc doesn't leave Insert mode
--   2 Hybrid                 files open in Insert mode; VS Code shortcuts work; Esc gives Normal mode
--   3 Modal with safety net  Normal mode by default; the VS Code shortcuts below still work
--   4 Pure Neovim            nothing added; LazyVim and your config decide every key
local state = require("nvs.state")
local coach = require("nvs.coach")

local M = {}

M.names = { "VS Code keys", "Hybrid", "Modal with safety net", "Pure Neovim" }

-- Keymaps we set, with whatever mapping they replaced (e.g. LazyVim's Ctrl+/
-- terminal), so a stage change removes ours and puts the original back.
local applied = {}
local group = vim.api.nvim_create_augroup("nvs_stage", { clear = true })

local function map(modes, lhs, rhs, desc, opts)
  opts = vim.tbl_extend("force", { desc = desc, silent = true }, opts or {})
  for _, m in ipairs(type(modes) == "table" and modes or { modes }) do
    local prev = vim.fn.maparg(lhs, m, false, true)
    table.insert(applied, { mode = m, lhs = lhs, prev = (prev.lhs and prev.buffer == 0) and prev or nil })
  end
  vim.keymap.set(modes, lhs, rhs, opts)
end

local function clear()
  for i = #applied, 1, -1 do
    local a = applied[i]
    pcall(vim.keymap.del, a.mode, a.lhs)
    if a.prev then
      vim.fn.mapset(a.mode, false, a.prev)
    end
  end
  applied = {}
  vim.api.nvim_clear_autocmds({ group = group })
end

-- VS Code shortcuts kept at stages 1 to 3. Each one also teaches its Vim equivalent.
local function vscode_keys()
  map({ "n", "i" }, "<C-z>", function()
    vim.cmd("undo")
    coach.hint("ctrl-z", "Ctrl+Z undid it. In Normal mode, u undoes and Ctrl+R redoes.")
  end, "Undo")

  for _, lhs in ipairs({ "<C-/>", "<C-_>" }) do -- terminals send Ctrl+/ as Ctrl+_
    map("n", lhs, function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gcc", true, false, true), "m", false)
      coach.hint("ctrl-/", "Ctrl+/ toggled the comment. In Normal mode: gcc. In Visual mode: gc.")
    end, "Toggle comment")
    map("x", lhs, "gc", "Toggle comment", { remap = true })
    map("i", lhs, "<C-o>gcc", "Toggle comment", { remap = true })
  end

  map({ "n", "i" }, "<C-S-k>", function()
    vim.cmd("normal! dd")
    coach.hint("ctrl-shift-k", "Ctrl+Shift+K deleted the line. In Normal mode: dd. 3dd deletes three lines.")
  end, "Delete line")

  map("n", "<C-f>", function()
    vim.api.nvim_feedkeys("/", "n", false)
    coach.hint("ctrl-f", "Ctrl+F opened search. In Normal mode / does the same; n and N jump between matches.")
  end, "Search in file")

  map({ "n", "i" }, "<C-p>", function()
    vim.cmd("stopinsert")
    Snacks.picker.files()
    coach.hint("ctrl-p", "Ctrl+P finds files. The Vim way: Space Space.")
  end, "Find file")

  map({ "n", "i" }, "<C-S-f>", function()
    vim.cmd("stopinsert")
    Snacks.picker.grep()
    coach.hint("ctrl-shift-f", "Ctrl+Shift+F searches the project. The Vim way: Space /.")
  end, "Search project")

  map({ "n", "i" }, "<C-b>", function()
    Snacks.explorer()
    coach.hint("ctrl-b", "Ctrl+B toggled the explorer. The Vim way: Space e.")
  end, "Explorer")

  map({ "n", "i" }, "<C-S-p>", function()
    vim.cmd("stopinsert")
    Snacks.picker.commands()
    coach.hint("ctrl-shift-p", "Ctrl+Shift+P lists commands. The Vim way: Space s C, or : for the command line.")
  end, "Command palette")

  map({ "n", "i" }, "<F1>", function()
    require("nvs.ask").open()
  end, "Ask how to do something")

  for _, key in ipairs({ "Up", "Down", "Left", "Right" }) do
    map({ "n", "i" }, "<" .. key .. ">", function()
      coach.arrow(key)
      return "<" .. key .. ">"
    end, "Move", { expr = true })
  end
end

local function is_file_buffer(buf)
  return vim.bo[buf].buftype == "" and vim.bo[buf].modifiable and vim.api.nvim_buf_get_name(buf) ~= ""
end

function M.apply(stage)
  clear()
  if stage <= 3 then
    vscode_keys()
  end
  if stage <= 2 then
    -- Open files ready for typing, the way VS Code does.
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(ev)
        if is_file_buffer(ev.buf) then
          vim.schedule(function()
            if vim.api.nvim_get_current_buf() == ev.buf and vim.fn.mode() == "n" then
              vim.cmd("startinsert")
            end
          end)
        end
      end,
    })
  end
  if stage == 1 then
    map("i", "<Esc>", function()
      coach.hint("esc-stage1", "Esc stays in Insert mode at Stage 1. :NvsStage 2 turns on Normal mode (Ctrl+\\ Ctrl+N works anytime).")
    end, "Stay in Insert mode (Stage 1)")
  end
end

function M.set(stage)
  stage = tonumber(stage)
  if not stage or stage < 1 or stage > 4 then
    vim.notify("Stage must be 1, 2, 3 or 4", vim.log.levels.WARN, { title = "nvs.ide" })
    return
  end
  state.data.stage = stage
  state.save()
  M.apply(stage)
  vim.notify(("Stage %d: %s"):format(stage, M.names[stage]), vim.log.levels.INFO, { title = "nvs.ide" })
end

return M
