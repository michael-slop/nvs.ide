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

local function tokens(text, syn)
  local out = {}
  for w in text:lower():gsub("[^%w%s]", " "):gmatch("%S+") do
    w = syn[w] or w
    if not STOP[w] then
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

-- Returns up to `limit` entries sorted by score (0..1).
function M.search(question, limit)
  local k = load()
  local qt = tokens(question, k.synonyms)
  if #qt == 0 then
    return {}
  end
  local qset = {}
  for _, w in ipairs(qt) do
    qset[w] = true
  end
  local idf = function(w)
    return math.log((k.n + 1) / ((k.df[w] or 0) + 0.5))
  end
  local results = {}
  for _, e in ipairs(k.entries) do
    local best = 0
    for _, phrase in ipairs(e._phrases) do
      if #phrase > 0 then
        local hit, total = 0, 0
        for _, w in ipairs(phrase) do
          total = total + idf(w)
          if qset[w] then
            hit = hit + idf(w)
          end
        end
        -- Reward phrases that cover the question, and questions that cover the phrase.
        local qcover = 0
        for _, w in ipairs(qt) do
          for _, p in ipairs(phrase) do
            if p == w then
              qcover = qcover + 1
              break
            end
          end
        end
        -- The small absolute term breaks ties in favour of phrases that share more words.
        local score = 0.6 * (hit / total) + 0.4 * (qcover / #qt) + 0.005 * qcover
        best = math.max(best, score)
      end
    end
    if best > 0 then
      table.insert(results, { entry = e, score = best })
    end
  end
  table.sort(results, function(a, b)
    return a.score > b.score
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
  local width = math.min(84, vim.o.columns - 6)
  local height = math.min(#lines + 1, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 3),
    col = math.floor((vim.o.columns - width) / 2),
    border = "single",
    title = " " .. title .. " ",
    title_pos = "left",
  })
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
