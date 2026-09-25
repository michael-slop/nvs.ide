-- Ask: type "how do I delete a line" and get the Vim way.
-- Answers come from kb/ask.json, written by hand. When none match well and
-- local AI is on, the question goes to the local model with the closest answers as context.
local state = require("nvs.state")

local M = {}

local kb -- lazily loaded { entries, synonyms, df, n }

local STOP = {}
for w in ([[a an the i me my to do does did how can could would should you your is are was be it
  this that these those of in on at for with and or from by into onto what which when where why
  vim neovim nvim please want get make use using way there some any just so like]]):gmatch("%S+") do
  STOP[w] = true
end

-- Each word once, in the order it appears. A repeated word ("line by line", or "split window"
-- once both halves map to "window") must not count twice in the scores below.
local function tokens(text, syn)
  local out, seen = {}, {}
  for w in text:lower():gsub("[^%w%s]", " "):gmatch("%S+") do
    w = syn[w] or w
    if not STOP[w] and not seen[w] then
      seen[w] = true
      out[#out + 1] = w
    end
  end
  return out
end

local function load()
  if kb then
    return kb
  end
  local file = vim.api.nvim_get_runtime_file("kb/ask.json", false)[1]
  local f = assert(io.open(assert(file, "kb/ask.json not found on runtimepath"), "r"))
  local data = vim.json.decode(f:read("*a"))
  f:close()
  kb = { entries = data.entries, synonyms = data.synonyms or {}, df = {}, n = #data.entries }
  for _, e in ipairs(kb.entries) do
    e._phrases = {}
    local seen = {}
    for _, q in ipairs(e.q) do
      local t = tokens(q, kb.synonyms)
      table.insert(e._phrases, t)
      for _, w in ipairs(t) do
        if not seen[w] then
          seen[w] = true
          kb.df[w] = (kb.df[w] or 0) + 1
        end
      end
    end
  end
  return kb
end

-- Returns up to `limit` entries sorted by score, best first (an exact phrase scores just over 1).
function M.search(question, limit)
  local k = load()
  local qt = tokens(question, k.synonyms)
  if #qt == 0 then
    return {}
  end
  local idf = function(w)
    return math.log((k.n + 1) / ((k.df[w] or 0) + 0.5))
  end
  -- The question's words and their total weight. A rare word ("explorer") weighs more than a
  -- common one ("open", "file"), so a phrase that has the rare word covers more of the question.
  local qset, qweight = {}, 0
  for _, w in ipairs(qt) do
    qset[w] = true
    qweight = qweight + idf(w)
  end
  local results = {}
  for order, e in ipairs(k.entries) do
    local best = 0
    for _, phrase in ipairs(e._phrases) do
      if #phrase > 0 then
        local hit, total, shared = 0, 0, 0
        for _, w in ipairs(phrase) do
          total = total + idf(w)
          if qset[w] then
            hit = hit + idf(w)
            shared = shared + 1
          end
        end
        -- Both directions, weighted: how much of the phrase the question covers, and how much
        -- of the question the phrase covers. A phrase that says exactly what was asked scores 1
        -- on both, so it always beats a partial match. "open a file" and "file explorer" both
        -- sit inside "open the file explorer"; the weighting lets "explorer" decide between
        -- them. The small absolute term favours the phrase sharing more words when the rest ties.
        local score = 0.6 * (hit / total) + 0.4 * (hit / qweight) + 0.005 * shared
        best = math.max(best, score)
      end
    end
    if best > 0 then
      table.insert(results, { entry = e, score = best, order = order })
    end
  end
  -- table.sort is not stable, so equal scores fall back to the order in kb/ask.json. Without
  -- that the same question could get a different answer on different runs.
  table.sort(results, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.order < b.order
  end)
  local out = {}
  for i = 1, math.min(limit or 3, #results) do
    out[i] = results[i]
  end
  return out
end

M.threshold = 0.45

local function entry_lines(e)
  local lines = {
    "## " .. e.q[1]:gsub("^%l", string.upper):gsub("%f[%w]i%f[%W]", "I"),
    "",
    "Vim:      `" .. e.keys .. "`",
    "VS Code:  " .. e.vscode,
    "",
  }
  for _, l in ipairs(vim.split(e.a, "\n")) do
    table.insert(lines, l)
  end
  return lines
end

-- Floating answer window. `actions` maps a key to { label, fn }.
local function show(title, lines, actions)
  local foot = {}
  for key, act in pairs(actions) do
    table.insert(foot, key .. " " .. act[1])
  end
  table.sort(foot)
  table.insert(foot, "q close")
  vim.list_extend(lines, { "", "---", table.concat(foot, "   ") })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  -- Fit the editor, but never ask for less than one cell: in a 6-line editor `vim.o.lines - 6`
  -- is 0 and nvim_open_win refuses a size that is not positive. A float that runs past the
  -- edge of a tiny editor is fine; only a zero size is an error.
  local width = math.max(1, math.min(84, vim.o.columns - 6))
  local height = math.max(1, math.min(#lines + 1, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 3)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    border = "single",
    title = " " .. title .. " ",
    title_pos = "left",
  })
  -- Ask is mostly reached from Insert mode: Stages 1-2 type by default and F1 is mapped there
  -- too. snacks.input then runs `startinsert` for the window it was opened from right before
  -- our callback, and that deferred Insert lands in whichever window is current once control
  -- returns to the main loop, which is this one. The buffer is not modifiable, so Insert mode
  -- here only raises E21 on q / Esc / 1-3, and at Stage 1 (Esc stays in Insert mode) there
  -- is no way out. `stopinsert` cancels the pending `startinsert`, or leaves Insert mode if we
  -- are already in it, and does not touch the next `i` elsewhere. The scheduled repeat catches
  -- a `startinsert` that something else had already scheduled before we got here.
  vim.cmd("stopinsert")
  vim.schedule(function()
    if vim.api.nvim_get_current_win() == win then
      vim.cmd("stopinsert")
    end
  end)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  for key, act in pairs(actions) do
    vim.keymap.set("n", key, function()
      close()
      act[2]()
    end, { buffer = buf, nowait = true })
  end
end

local function ask_model(question, context)
  local ai = require("nvs.ai")
  local ref = {}
  for _, r in ipairs(context) do
    table.insert(ref, ("- %s: %s (Vim: %s)"):format(r.entry.q[1], r.entry.a, r.entry.keys))
  end
  local system = table.concat({
    "You are the help assistant inside nvs.ide, an editor built on Neovim with the LazyVim distribution.",
    "The user is moving from VS Code to Vim. Answer in at most six short sentences, plainly.",
    "Name the exact keys. The leader key is Space.",
    "If an Ex command does the job, put it on its own line starting with ':' inside a ```vim block.",
    "Reference answers that may help:",
    table.concat(ref, "\n"),
  }, "\n")
  vim.notify("Asking the local model…", vim.log.levels.INFO, { title = "nvs.ide · Ask" })
  ai.chat({ { role = "system", content = system }, { role = "user", content = question } }, function(err, text, model)
    if err then
      return vim.notify(err, vim.log.levels.WARN, { title = "nvs.ide · Ask" })
    end
    local lines = vim.split(text, "\n")
    local cmds = {}
    for _, l in ipairs(lines) do
      local c = l:match("^%s*:(%S.*)$")
      if c then
        table.insert(cmds, c)
      end
    end
    local actions = {}
    if #cmds > 0 then
      actions.r = {
        "run a suggested command",
        function()
          vim.ui.select(cmds, { prompt = "Run which command? (suggested by " .. model .. ")" }, function(c)
            if c then
              vim.cmd(c)
            end
          end)
        end,
      }
    end
    table.insert(lines, 1, "")
    table.insert(lines, 1, "_Answer from " .. model .. ", not from the written guide._")
    show("Ask: " .. question, lines, actions)
  end)
end

function M.answer(question)
  local results = M.search(question, 4)
  local best = results[1]
  if not best or best.score < M.threshold then
    if state.data.ai.enabled then
      return ask_model(question, results)
    end
    local lines = { "No written answer matches that well.", "" }
    if #results > 0 then
      table.insert(lines, "Closest topics:")
      for i, r in ipairs(results) do
        table.insert(lines, ("  %d. %s  `%s`"):format(i, r.entry.q[1], r.entry.keys))
      end
    end
    vim.list_extend(lines, { "", "Turn on a local model with :NvsAI on to get free-form answers." })
    local actions = {}
    for i, r in ipairs(results) do
      actions[tostring(i)] = { "open " .. i, function() M.show_entry(r.entry, question) end }
    end
    return show("Ask: " .. question, lines, actions)
  end
  M.show_entry(best.entry, question, vim.list_slice(results, 2))
end

function M.show_entry(e, question, others)
  local lines = entry_lines(e)
  local actions = {}
  if e.try then
    actions.r = { "run :" .. e.try, function() vim.cmd(e.try) end }
  end
  if others and #others > 0 then
    vim.list_extend(lines, { "", "Related:" })
    for i, r in ipairs(others) do
      table.insert(lines, ("  %d. %s  `%s`"):format(i, r.entry.q[1], r.entry.keys))
      actions[tostring(i)] = { "open " .. i, function() M.show_entry(r.entry, question) end }
    end
  end
  if state.data.ai.enabled then
    actions.o = { "ask the local model instead", function() ask_model(question, { { entry = e } }) end }
  end
  show("Ask: " .. (question or e.q[1]), lines, actions)
end

function M.open(question)
  if question and question ~= "" then
    return M.answer(question)
  end
  vim.ui.input({ prompt = "Ask how to… " }, function(q)
    if q and q ~= "" then
      M.answer(q)
    end
  end)
end

return M
