-- Main-loop checks for the nvs.ide runtime: modes, keys and windows as a person meets them.
-- Run through tests/run.ps1, which starts Neovim headless and calls this file from a timer
-- after VimEnter. The checks run in a coroutine that yields to the main loop between steps,
-- and keys go in through nvim_input, so BufEnter, startinsert, mappings and pickers behave
-- exactly as they do when someone types. Every line printed starts with PASS or FAIL.
local out = {}
local function check(name, ok, detail)
  table.insert(out, (ok and "PASS " or "FAIL ") .. "ui: " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
end
local function finish(code)
  io.write(table.concat(out, "\n") .. "\n")
  io.flush()
  os.exit(code)
end
-- A prompt that waits for a person would hang a headless run forever; timers still fire
-- while input waits, so bail out.
vim.defer_fn(function()
  table.insert(out, "FAIL ui: harness hung 90 s (a step left Neovim waiting for input)")
  finish(2)
end, 90000)

local co
-- Return to the main loop for `ms`, then continue here. Typed keys, scheduled callbacks
-- and startinsert all take effect while we are away.
local function yield(ms)
  vim.defer_fn(function()
    local ok, err = coroutine.resume(co)
    if not ok then
      table.insert(out, "FAIL ui: harness error: " .. tostring(err))
      finish(3)
    end
  end, ms or 60)
  coroutine.yield()
end
local function type_keys(k, ms)
  vim.api.nvim_input(k)
  yield(ms or 150)
end
local function messages()
  return vim.api.nvim_exec2("messages", { output = true }).output
end
local function clear_messages()
  vim.cmd("messages clear")
end
local function mode()
  return vim.fn.mode()
end
local function tmpfile(name, lines)
  local dir = vim.fn.stdpath("cache") .. "/nvs-tests"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  vim.fn.writefile(lines or { "line one", "line two", "line three" }, path)
  return path
end
local function open(path)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  yield(200)
end
local function close_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
  end
end
-- Back to one Normal-mode window with an empty buffer.
local function reset()
  type_keys("<C-\\><C-n>", 100)
  close_floats()
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  yield(100)
  clear_messages()
end

local function run()
  -- lazy.nvim fires VeryLazy from UIEnter, which never comes headless; fire it here so
  -- config/keymaps.lua (the nvs commands) and the VeryLazy plugins load as they do for a person.
  vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  vim.wait(1500, function() return package.loaded["snacks"] ~= nil and vim.fn.exists(":NvsTutor") == 2 end, 50)
  yield(200)
  check("nvs commands exist after VeryLazy", vim.fn.exists(":NvsTutor") == 2)
  check("snacks loaded", package.loaded["snacks"] ~= nil)
  local stages = require("nvs.stages")
  local state = require("nvs.state")

  -- Stage 2: a file opens in Insert mode, Esc gives Normal mode, and coming back to the
  -- file (after closing a split, help, a picker) does NOT put you back in Insert mode.
  stages.set(2)
  reset()
  local f = tmpfile("stage2.txt")
  open(f)
  check("stage 2 file opens in Insert mode", mode() == "i", mode())
  type_keys("<Esc>")
  check("stage 2 Esc gives Normal mode", mode() == "n", mode())
  vim.cmd("new")
  yield(150)
  vim.cmd("close")
  yield(250)
  check("stage 2 back from a split stays in Normal mode", mode() == "n" and vim.api.nvim_buf_get_name(0) == vim.fn.fnamemodify(f, ":p"), mode())
  vim.cmd("help")
  yield(150)
  vim.cmd("close")
  yield(250)
  check("stage 2 back from help stays in Normal mode", mode() == "n", mode())
  type_keys("dd", 150)
  check("stage 2 dd deletes a line after coming back", vim.api.nvim_buf_line_count(0) == 2, vim.api.nvim_buf_line_count(0))
  -- A buffer that becomes a file later (:enew, then :w name) gets the same once-only rule.
  reset()
  vim.cmd("enew")
  yield(150)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "born unnamed" })
  local named = vim.fn.stdpath("cache") .. "/nvs-tests/named-later.txt"
  vim.cmd("write! " .. vim.fn.fnameescape(named))
  yield(200)
  type_keys("<C-\\><C-n>", 100)
  vim.cmd("help")
  yield(150)
  vim.cmd("close")
  yield(250)
  check("stage 2 a buffer named after :enew does not re-enter Insert mode", mode() == "n", mode())

  -- Ask, the way a person reaches it: F1, type the question, Enter. The answer window
  -- must be in Normal mode so q / Esc / 1-3 work, at every stage.
  for _, s in ipairs({ 1, 2 }) do
    stages.set(s)
    reset()
    open(tmpfile("ask" .. s .. ".txt"))
    clear_messages()
    -- F1 is the Ask key at stages 1-3; going through the mapping keeps vim.ui.input in the
    -- main loop (a direct :NvsAsk from here would block on the built-in input()).
    type_keys("<F1>", 400)
    type_keys("delete a line<CR>", 600)
    local win = vim.api.nvim_get_current_win()
    local float = vim.api.nvim_win_get_config(win).relative ~= ""
    check(("stage %d Ask answer opens as a float"):format(s), float and vim.bo.filetype == "markdown", vim.bo.filetype)
    check(("stage %d Ask answer is in Normal mode"):format(s), mode() == "n", mode())
    type_keys("q", 200)
    check(("stage %d q closes the Ask answer"):format(s), not vim.api.nvim_win_is_valid(win))
    check(("stage %d Ask leaves no E21"):format(s), not messages():find("E21"), messages():sub(1, 120))
  end

  -- Ask in a short editor must not error.
  do
    stages.set(2)
    reset()
    open(tmpfile("short.txt"))
    local lines = vim.o.lines
    vim.o.lines = 6
    local ok, err = pcall(require("nvs.ask").answer, "delete a line")
    yield(100)
    check("Ask survives a 6-line editor", ok, err)
    close_floats()
    vim.o.lines = lines
  end

  -- Stage 1: always typing. Ctrl+B and Ctrl+F must work from Insert mode without E21.
  stages.set(1)
  reset()
  open(tmpfile("stage1.txt"))
  check("stage 1 file opens in Insert mode", mode() == "i", mode())
  type_keys("<Esc>")
  check("stage 1 Esc stays in Insert mode", mode() == "i", mode())
  clear_messages()
  type_keys("<C-b>", 600)
  local ft = vim.bo.filetype
  check("stage 1 Ctrl+B opens the explorer", ft:find("snacks") ~= nil, ft)
  type_keys("j", 200)
  check("stage 1 explorer keys work (no E21)", not messages():find("E21"), messages():sub(1, 120))
  -- Stage 1 is "always typing": closing the explorer puts the caret back in the file.
  type_keys("q", 400)
  check("stage 1 is back in the file after the explorer", vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0):find("stage1%.txt") ~= nil, vim.api.nvim_buf_get_name(0))
  check("stage 1 returns to Insert mode after the explorer", mode() == "i", mode())
  reset()
  open(tmpfile("stage1b.txt", { "first line", "the needle is here", "last line" }))
  clear_messages()
  vim.fn.setreg("/", "")
  -- Ctrl+F, the search text, Enter; the Escapes cancel any prompt a broken mapping leaves open.
  type_keys("<C-f>needle<CR>", 300)
  type_keys("<Esc><Esc>", 100)
  check("stage 1 Ctrl+F searches from Insert mode", vim.fn.getreg("/") == "needle" and vim.fn.line(".") == 2, ("reg=%s line=%d"):format(vim.fn.getreg("/"), vim.fn.line(".")))
  check("stage 1 Ctrl+F leaves no E21", not messages():find("E21"), messages():sub(1, 120))

  -- The tutor opens in Normal mode at every stage, and its "press Esc" lessons work at Stage 1.
  for _, s in ipairs({ 1, 2 }) do
    stages.set(s)
    reset()
    vim.cmd("NvsTutor")
    yield(500)
    check(("stage %d tutor is the tutor buffer"):format(s), vim.api.nvim_buf_get_name(0):find("nvs%-ide%.tutor") ~= nil, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    check(("stage %d tutor opens in Normal mode"):format(s), mode() == "n", mode())
    type_keys("i", 100)
    type_keys("<Esc>", 200)
    check(("stage %d Esc leaves Insert mode inside the tutor"):format(s), mode() == "n", mode())
  end

  -- Stage changes restore LazyVim's GLOBAL maps even when a buffer-local map shadows them.
  do
    stages.set(2)
    reset()
    vim.cmd("enew")
    vim.keymap.set("n", "<C-p>", "<Nop>", { buffer = true, desc = "buffer-local shadow" })
    stages.set(3)
    stages.set(4)
    vim.cmd("enew")
    local m = vim.fn.maparg("<C-p>", "n", false, true)
    check("stage 4 has no global <C-p> after a buffer-local shadow", (m.lhs == nil) or (m.buffer == 1), vim.inspect(m.desc))
    stages.set(2)
    vim.cmd("enew")
    m = vim.fn.maparg("<C-p>", "n", false, true)
    check("stage 2 <C-p> is Find file again", m.desc == "Find file", m.desc)
  end

  -- State: a bad value in nvs-ide.json is repaired, not fatal.
  do
    local file = vim.fn.stdpath("data") .. "/nvs-ide.json"
    local keep = vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or nil
    vim.fn.writefile({ '{"stage":"2","coach":5,"ai":{"enabled":"yes","llamacpp":{"port":"abc"}}}' }, file)
    local ok, err = pcall(state.load)
    check("state.load survives wrong types", ok, err)
    check("state stage is a number", type(state.data.stage) == "number", type(state.data.stage))
    check("state coach is a known value", ({ always = 1, three = 1, once = 1, off = 1 })[state.data.coach] ~= nil, state.data.coach)
    check("state ai.enabled is a boolean", type(state.data.ai.enabled) == "boolean", type(state.data.ai.enabled))
    check("state port is a number", type(state.data.ai.llamacpp.port) == "number", type(state.data.ai.llamacpp.port))
    if keep then vim.fn.writefile(keep, file) else os.remove(file) end
    state.load()
  end

  -- Coach frequency and ghost text are settable without editing JSON.
  check(":NvsCoach exists", vim.fn.exists(":NvsCoach") == 2)

  -- Ask answers the questions the review found flipping on ties.
  do
    local ask = require("nvs.ask")
    local function top(q) local r = ask.search(q, 1)[1]; return r and r.entry.id or "" end
    check("ask: open the file explorer", top("open the file explorer") == "explorer", top("open the file explorer"))
    check("ask: close window", top("close window") ~= "exit-vim", top("close window"))
    local a, b = top("run a command"), top("run a command")
    check("ask: run a command is stable", a == b and a ~= "", a .. "/" .. b)
  end

  -- Highlight groups the theme must own (the review found 26 using Neovim's stock colours).
  do
    local palette = {}
    local src = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/colors/necronomicon.lua"), "\n")
    for hex in src:gmatch('"(#%x%x%x%x%x%x)"') do palette[tonumber(hex:sub(2), 16)] = true end
    local off = {}
    for _, g in ipairs({ "DiagnosticUnderlineInfo", "DiagnosticUnderlineHint", "DiagnosticUnderlineOk", "QuickFixLine", "WinBar", "WinBarNC",
      "SpellBad", "SpellCap", "SpellRare", "SpellLocal", "RenderMarkdownH5Bg", "RenderMarkdownH6Bg" }) do
      local hl = vim.api.nvim_get_hl(0, { name = g, link = false })
      for _, k in ipairs({ "fg", "bg", "sp" }) do
        if hl[k] and not palette[hl[k]] then table.insert(off, g .. "." .. k) end
      end
      if vim.tbl_isempty(hl) then table.insert(off, g .. " undefined") end
    end
    check("theme owns the review's highlight groups", #off == 0, table.concat(off, ","))
  end

  stages.set(2)
  reset()
  check("no errors in :messages", not messages():find("E%d+:") and not messages():find("Error"), messages():sub(1, 300))
  finish(0)
end

co = coroutine.create(run)
local ok, err = coroutine.resume(co)
if not ok then
  table.insert(out, "FAIL ui: harness error: " .. tostring(err))
  finish(3)
end
