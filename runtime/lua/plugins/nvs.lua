-- Plugins nvs.ide adds on top of LazyVim.
local state = require("nvs.state")

return {
  -- Ghost-text completion from a local model, like Copilot but on your own machine.
  -- Only loads when local AI is on (:NvsOllama on, then restart).
  {
    "milanglacier/minuet-ai.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cond = function()
      return state.data.ollama.enabled and state.data.ollama.ghost_text
    end,
    event = "InsertEnter",
    opts = function()
      local o = state.data.ollama
      return {
        provider = "openai_fim_compatible",
        n_completions = 1,
        context_window = 512,
        provider_options = {
          openai_fim_compatible = {
            api_key = "TERM", -- Ollama needs no key; minuet wants the name of any set variable
            name = "Ollama",
            end_point = o.url:gsub("/+$", "") .. "/v1/completions",
            model = o.complete_model,
            optional = { max_tokens = 56, top_p = 0.9 },
          },
        },
        virtualtext = {
          auto_trigger_ft = { "*" },
          keymap = {
            accept = "<A-a>",
            accept_line = "<A-l>",
            next = "<A-]>",
            prev = "<A-[>",
            dismiss = "<A-e>",
          },
        },
      }
    end,
  },

  -- Show the completion menu's documentation next to it, the way VS Code does.
  {
    "saghen/blink.cmp",
    opts = {
      completion = {
        documentation = { auto_show = true, auto_show_delay_ms = 200 },
        ghost_text = { enabled = true },
      },
    },
  },
}
