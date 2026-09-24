-- nvs.ide transition layer: commands, keymaps and the first-run welcome.
local state = require("nvs.state")
local stages = require("nvs.stages")

local M = {}

local function welcome()
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

  vim.api.nvim_create_user_command("NvsOllama", function(o)
    require("nvs.ollama").command(o.args)
  end, {
    nargs = "*",
    complete = function()
      return { "on", "off", "status", "model", "url" }
    end,
    desc = "nvs.ide: local AI (Ollama) settings",
  })

  vim.api.nvim_create_user_command("NvsWelcome", welcome, { desc = "nvs.ide: choose your stage again" })

  -- Replaces LazyVim's buffer-keymaps popup on <leader>?; <leader>sk still searches every keymap.
  vim.keymap.set("n", "<leader>?", function()
    require("nvs.ask").open()
  end, { desc = "Ask how to… (nvs.ide)" })
  vim.keymap.set("n", "<leader>Nt", "<cmd>NvsTutor<cr>", { desc = "Tutor (nvs.ide)" })
  vim.keymap.set("n", "<leader>Ns", "<cmd>NvsStage<cr>", { desc = "Keybinding stage (nvs.ide)" })
  vim.keymap.set("n", "<leader>No", "<cmd>NvsOllama status<cr>", { desc = "Local AI status (nvs.ide)" })
  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add({ { "<leader>N", group = "nvs.ide" } })
  end

  if not state.data.welcomed and #vim.api.nvim_list_uis() > 0 then
    vim.schedule(welcome)
  end
end

return M
