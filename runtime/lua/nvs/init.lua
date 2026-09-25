-- nvs.ide transition layer: commands, keymaps and the first-run welcome.
local state = require("nvs.state")
local stages = require("nvs.stages")
local coach = require("nvs.coach")

local M = {}

local function welcome()
  -- Inside the nvs.ide window the Welcome screen is native; the window draws it.
  if vim.g.nvs_shell and require("nvs.bridge").open("welcome") then
    return
  end
  local choices = {
    { label = "I'm coming from VS Code", stage = 1 },
    { label = "I know a little Vim", stage = 2 },
    { label = "I use Vim, but keep a few safety nets", stage = 3 },
    { label = "I'm a Neovim user", stage = 4 },
  }
  vim.ui.select(choices, {
    prompt = "Welcome to nvs.ide. Where are you coming from?",
    format_item = function(c)
      return ("%s  →  Stage %d, %s"):format(c.label, c.stage, stages.names[c.stage])
    end,
  }, function(choice)
    state.data.welcomed = true
    state.save()
    if choice then
      stages.set(choice.stage)
      vim.notify("Space ? (or F1) answers 'how do I…' questions. :NvsTutor has lessons. :NvsStage changes this later.", vim.log.levels.INFO, { title = "nvs.ide" })
    end
  end)
end

function M.setup()
  state.load()
  stages.apply(state.data.stage)

  -- Inside the nvs.ide shell, stream workbench state to it.
  if vim.g.nvs_shell then
    require("nvs.bridge").setup()
  end

  vim.api.nvim_create_user_command("NvsStage", function(o)
    if o.args == "" then
      local items = {}
      for i, n in ipairs(stages.names) do
        items[i] = { n = i, name = n }
      end
      vim.ui.select(items, {
        prompt = "Keybinding stage (now " .. state.data.stage .. ")",
        format_item = function(it)
          return ("%d · %s"):format(it.n, it.name)
        end,
      }, function(it)
        if it then
          stages.set(it.n)
        end
      end)
    else
      stages.set(o.args)
    end
  end, { nargs = "?", desc = "nvs.ide: set the keybinding stage (1-4)" })

  vim.api.nvim_create_user_command("NvsAsk", function(o)
    require("nvs.ask").open(o.args)
  end, { nargs = "*", desc = "nvs.ide: ask how to do something" })

  vim.api.nvim_create_user_command("NvsTutor", function()
    vim.cmd("Tutor nvs-ide")
  end, { desc = "nvs.ide: open the lessons" })

  vim.api.nvim_create_user_command("NvsAI", function(o)
    require("nvs.ai").command(o.args)
  end, {
    nargs = "*",
    complete = function(lead, line)
      if line:match("backend%s+") then
        return { "llamacpp", "ollama", "openai" }
      end
      return vim.tbl_filter(function(c)
        return c:find(lead, 1, true) == 1
      end, { "on", "off", "status", "backend", "url", "port", "server", "stop" })
    end,
    desc = "nvs.ide: local AI settings",
  })

  vim.api.nvim_create_user_command("NvsModel", function(o)
    require("nvs.ai").model_command(o.args)
  end, {
    nargs = "*",
    complete = function()
      return { "pull", "folder" }
    end,
    desc = "nvs.ide: choose or download a local model",
  })

  vim.api.nvim_create_user_command("NvsCoach", function(o)
    coach.command(o.args)
  end, {
    nargs = "*",
    complete = function(lead, line)
      local words = vim.list_extend(vim.deepcopy(coach.frequencies), { "ghost" })
      if line:match("ghost%s+") then
        words = { "on", "off" }
      end
      return vim.tbl_filter(function(c)
        return c:find(lead, 1, true) == 1
      end, words)
    end,
    desc = "nvs.ide: coach hints (always|three|once|off) and ghost text (ghost on|off)",
  })

  -- Start the built-in llama.cpp server the first time ghost text is likely to be needed.
  if state.data.ai.enabled and state.data.ai.ghost_text then
    vim.api.nvim_create_autocmd("InsertEnter", {
      once = true,
      callback = function()
        require("nvs.ai").ensure()
      end,
    })
  end

  vim.api.nvim_create_user_command("NvsWelcome", welcome, { desc = "nvs.ide: choose your stage again" })

  -- The Settings screen lives in the window. In a terminal, say where the values are.
  vim.api.nvim_create_user_command("NvsSettings", function()
    if vim.g.nvs_shell and require("nvs.bridge").open("settings") then
      return
    end
    local prefs = require("nvs.prefs")
    vim.notify(
      ("The Settings screen is part of the nvs.ide window. Values are in %s; the generated file is %s."):format(
        vim.fn.stdpath("data") .. "/nvs-settings.json", prefs.settings_file()),
      vim.log.levels.INFO, { title = "nvs.ide" })
    if vim.fn.filereadable(prefs.settings_file()) == 1 then
      vim.cmd.edit(vim.fn.fnameescape(prefs.settings_file()))
    end
  end, { desc = "nvs.ide: the Settings screen (in the window)" })

  -- Replaces LazyVim's buffer-keymaps popup on <leader>?; <leader>sk still searches every keymap.
  vim.keymap.set("n", "<leader>?", function()
    require("nvs.ask").open()
  end, { desc = "Ask how to… (nvs.ide)" })
  vim.keymap.set("n", "<leader>Nt", "<cmd>NvsTutor<cr>", { desc = "Tutor (nvs.ide)" })
  vim.keymap.set("n", "<leader>Ns", "<cmd>NvsStage<cr>", { desc = "Keybinding stage (nvs.ide)" })
  vim.keymap.set("n", "<leader>Na", "<cmd>NvsAI status<cr>", { desc = "Local AI status (nvs.ide)" })
  vim.keymap.set("n", "<leader>Nm", "<cmd>NvsModel<cr>", { desc = "Choose a local model (nvs.ide)" })
  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add({ { "<leader>N", group = "nvs.ide" } })
  end

  if not state.data.welcomed and #vim.api.nvim_list_uis() > 0 then
    vim.schedule(welcome)
  end
end

return M
