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

-- Wraps a function that opens a window (a picker, the explorer, Ask's prompt) so the
-- window opens from Normal mode. The list buffers take Normal-mode keys and cannot be
-- typed into (E21), and a prompt's own :startinsert (snacks.input, the picker input) is
-- ignored while Insert mode is still active. :stopinsert only takes effect after the
-- mapping returns, so the open is scheduled to run once it has.
local function from_normal(open)
  return function()
    vim.cmd("stopinsert")
    vim.schedule(open)
  end
end

-- Coach hints from <expr> mappings. The expression runs while Neovim is still reading
-- keys and may not change windows (:help :map-expression), so the notification waits a tick.
local function hint_later(id, text)
  vim.schedule(function()
    coach.hint(id, text)
  end)
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

  -- Search from either mode. The keys are returned rather than fed from the callback, so
  -- whatever is typed right after Ctrl+F lands in the search prompt, in order. Outside Normal
  -- mode, i_CTRL-O runs the search and comes back to typing once it is done. That covers
  -- Replace mode as well (the Insert key toggles it, and the "i" map applies there), where
  -- mode() says "R" and a bare "/" would be typed over the text.
  map({ "n", "i" }, "<C-f>", function()
    hint_later("ctrl-f", "Ctrl+F opened search. In Normal mode / does the same; n and N jump between matches.")
    return vim.fn.mode():sub(1, 1) == "n" and "/" or "<C-o>/"
  end, "Search in file", { expr = true })

  map({ "n", "i" }, "<C-p>", from_normal(function()
    Snacks.picker.files()
    coach.hint("ctrl-p", "Ctrl+P finds files. The Vim way: Space Space.")
  end), "Find file")

  map({ "n", "i" }, "<C-S-f>", from_normal(function()
    Snacks.picker.grep()
    coach.hint("ctrl-shift-f", "Ctrl+Shift+F searches the project. The Vim way: Space /.")
  end), "Search project")

  map({ "n", "i" }, "<C-b>", from_normal(function()
    Snacks.explorer()
    coach.hint("ctrl-b", "Ctrl+B toggled the explorer. The Vim way: Space e.")
  end), "Explorer")

  map({ "n", "i" }, "<C-S-p>", from_normal(function()
    Snacks.picker.commands()
    coach.hint("ctrl-shift-p", "Ctrl+Shift+P lists commands. The Vim way: Space s C, or : for the command line.")
  end), "Command palette")

  map({ "n", "i" }, "<F1>", from_normal(function()
    require("nvs.ask").open()
  end), "Ask how to do something")

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

-- The tutor is a real file (*.tutor, filetype tutor) whose lessons teach Normal mode, and
-- :Tutor marks its buffer (buftype=nowrite) only after entering it.
local function is_tutor(buf)
  return vim.bo[buf].filetype == "tutor" or vim.api.nvim_buf_get_name(buf):match("%.tutor$") ~= nil
end

function M.apply(stage)
  clear()
  if stage <= 3 then
    vscode_keys()
  end
  if stage <= 2 then
    -- A file opens ready for typing, the way VS Code puts the caret in a new editor. At
    -- Stage 1 (always typing) that holds on every return to a file, so closing the explorer,
    -- a picker or Ask puts the caret back. At Stage 2 it holds once, the first time the
    -- buffer is entered this session: the user may have left Insert mode on purpose, and
    -- before, every return put them back and the next "dd" typed "dd".
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(ev)
        -- Every buffer is marked, not only file buffers: a New File buffer (:enew) becomes a
        -- file once it is written (:w name.txt), and that later return is not a first open.
        local seen = vim.b[ev.buf].nvs_entered
        vim.b[ev.buf].nvs_entered = true
        if (stage == 2 and seen) or not is_file_buffer(ev.buf) or is_tutor(ev.buf) then
          return
        end
        -- Decided again once the command that opened the buffer has finished: by then
        -- :Tutor has set its buftype, and the user may already be somewhere else.
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == ev.buf and vim.fn.mode() == "n" and is_file_buffer(ev.buf) and not is_tutor(ev.buf) then
            vim.cmd("startinsert")
          end
        end)
      end,
    })
  end
  if stage == 1 then
    -- Esc stays in Insert mode in a file (named or not yet). Anywhere else it is a real Esc:
    -- the tutor's lessons say "press Esc", and a picker prompt, which Ctrl+P opens typing,
    -- closes with Esc, Esc. Special buffers all carry a buftype (prompt, nofile, help...).
    map("i", "<Esc>", function()
      if vim.bo.buftype ~= "" or is_tutor(0) then
        return "<Esc>"
      end
      hint_later("esc-stage1", "Esc stays in Insert mode at Stage 1. :NvsStage 2 turns on Normal mode (Ctrl+\\ Ctrl+N works anytime).")
      return ""
    end, "Stay in Insert mode (Stage 1)", { expr = true })
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
  vim.api.nvim_exec_autocmds("User", { pattern = "NvsStateChanged", modeline = false })
end

return M
