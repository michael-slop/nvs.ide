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

  -- The nvs.ide shell draws its own tab strip and status bar; the in-grid ones would double up.
  { "akinsho/bufferline.nvim", enabled = not vim.g.nvs_shell },
  { "nvim-lualine/lualine.nvim", enabled = not vim.g.nvs_shell },

  -- Under tests/run.ps1 (NVS_TEST set) nothing downloads: language servers and parsers
  -- spawn child processes that outlive the check and collide between sandboxes.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      if vim.env.NVS_TEST then
        opts.ensure_installed = {}
      end
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if vim.env.NVS_TEST then
        opts.ensure_installed = {}
      end
    end,
  },

  -- Show the completion menu's documentation next to it, the way VS Code does, and honour
  -- the Completion settings (vim.g.nvs_settings comes from lua/nvs/settings.lua).
  {
    "saghen/blink.cmp",
    opts = function(_, opts)
      local s = vim.g.nvs_settings or {}
      opts.completion = opts.completion or {}
      opts.completion.documentation = vim.tbl_extend("force", opts.completion.documentation or {}, { auto_show = s.cmp_docs ~= false, auto_show_delay_ms = 200 })
      opts.completion.ghost_text = vim.tbl_extend("force", opts.completion.ghost_text or {}, { enabled = s.cmp_ghost ~= false })
      if s.cmp_auto == false then
        opts.completion.menu = vim.tbl_extend("force", opts.completion.menu or {}, { auto_show = false })
      end
      if s.cmp_accept then
        opts.keymap = vim.tbl_extend("force", opts.keymap or {}, { preset = s.cmp_accept })
      end
      if s.cmp_snippets == false and opts.sources and type(opts.sources.default) == "table" then
        opts.sources.default = vim.tbl_filter(function(src)
          return src ~= "snippets"
        end, opts.sources.default)
      end
    end,
  },

  -- Git and Languages settings.
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      local s = vim.g.nvs_settings or {}
      if s.git_signs ~= nil then
        opts.signcolumn = s.git_signs
      end
      if s.git_blame ~= nil then
        opts.current_line_blame = s.git_blame
      end
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      local s = vim.g.nvs_settings or {}
      if s.inlay_hints ~= nil then
        opts.inlay_hints = vim.tbl_extend("force", opts.inlay_hints or {}, { enabled = s.inlay_hints })
      end
      opts.diagnostics = opts.diagnostics or {}
      if s.virtual_text == false then
        opts.diagnostics.virtual_text = false
      end
      if s.diag_signs == false then
        opts.diagnostics.signs = false
      end
      if s.update_in_insert ~= nil then
        opts.diagnostics.update_in_insert = s.update_in_insert
      end
    end,
  },
}
