-- Plugins nvs.ide adds on top of LazyVim.
local state = require("nvs.state")

return {
  -- Ghost-text completion from a local model, like Copilot but on your own machine.
  -- Only loads when local AI is on (:NvsAI on, then restart). Works with the built-in
  -- llama.cpp backend and with Ollama; plain OpenAI-compatible servers rarely do fill-in-the-middle.
  {
    "milanglacier/minuet-ai.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cond = function()
      local a = state.data.ai
      return a.enabled and a.ghost_text and a.backend ~= "openai"
    end,
    event = "InsertEnter",
    opts = function()
      local ai = require("nvs.ai")
      local a = state.data.ai
      local model = a.complete_model ~= "" and a.complete_model or a.chat_model
      local fim = {
        api_key = "TERM", -- local servers need no key; minuet wants the name of any set variable
        name = a.backend == "llamacpp" and "llama.cpp" or "Ollama",
        end_point = ai.base_url() .. "/v1/completions",
        model = model ~= "" and model or "default",
        optional = { max_tokens = 56, top_p = 0.9 },
      }
      if a.backend == "llamacpp" then
        -- llama-server's /v1/completions takes a raw prompt, so build the model's FIM prompt here.
        local template = ai.fim_template(model)
        fim.template = {
          prompt = function(before, after)
            return template:format(before, after)
          end,
          suffix = false,
        }
      end
      return {
        provider = "openai_fim_compatible",
        n_completions = 1,
        context_window = 512,
        provider_options = { openai_fim_compatible = fim },
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
