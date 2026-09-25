<p align="center"><img src="assets/nvs.ide.png" width="96" height="96" alt="nvs.ide icon: the necronomicon"></p>

# nvs.ide

**LazyVim with training wheels, for people leaving VS Code.** Free and open
source under the [MIT license](LICENSE). (`nvs.ide` is a working name.)

nvs.ide is a middle ground between VS Code and Neovim. Underneath it's stock
Neovim running the full [LazyVim](https://github.com/LazyVim/LazyVim) setup. On
top it adds the hand-holding VS Code users expect, and takes it away a step at a
time:

- **Four stages** from VS Code keys to pure Neovim. Ctrl+S, Ctrl+Z, Ctrl+/,
  Ctrl+P and friends keep working until you're ready to drop them.
- **A coach** that shows the Vim way after you do something the VS Code way
  ("Ctrl+Shift+K deleted the line. In Normal mode: dd").
- **Ask**: press F1 or `Space ?` and type "how do I split the screen". Answers
  come from a written guide, with the Vim keys, the VS Code keys and a Try it
  action.
- **Lessons**: `:NvsTutor` runs nine interactive lessons in a real buffer.
- **Completion**: LazyVim's blink.cmp menu with documentation, plus optional
  ghost-text suggestions from a local model.
- **Local AI, any model, no Ollama required**: nvs.ide runs llama.cpp itself and
  loads any GGUF model, including ones it downloads from Hugging Face for you. Ask
  falls back to the model when the guide has no answer, and ghost text uses it
  for Copilot-style suggestions. Ollama and OpenAI-compatible servers (LM
  Studio, vLLM, llamafile) work too. Nothing leaves your machine.

The plan is a native window around Neovim (a Neovide fork) with VS Code's
workbench: explorer, settings screen, plugin browser and panels.
[docs/preview/index.html](docs/preview/index.html) is an interactive mockup of
it, and [docs/design.md](docs/design.md) is the design.

## Status

| Part | State |
|---|---|
| `runtime/`: LazyVim + stages, coach, Ask, lessons, local AI | Works today in Neovide or a terminal |
| `docs/preview/`: interactive design mockup | Done |
| `shell/`: native window (Neovide fork) | Phase 1, not started |
| Settings and Plugins screens | In the mockup only |
| Open VSX extension host | Later phase |

## Try the runtime

It runs as a separate Neovim app (`NVIM_APPNAME=nvs-ide`), so your own config,
plugins and data are left alone.

```powershell
git clone https://github.com/michael-slop/nvs.ide
cd nvs.ide
.\scripts\try.ps1            # Neovide
.\scripts\try.ps1 -Terminal  # nvim in this terminal
.\scripts\try.ps1 -Shortcut  # add an nvs.ide shortcut, with its icon, to the Start menu
```

The first start installs LazyVim and its plugins, then asks where you're coming
from and picks a stage.

**Needs:** Neovim 0.11 or newer, git, a C compiler, curl, and the
`tree-sitter` CLI for LazyVim's syntax parsers. ripgrep, fd and lazygit are
recommended. On Windows, run `git config --global core.longpaths true` if a
plugin fails to clone.

### Commands

| Command | What it does |
|---|---|
| `:NvsStage [1-4]` | Pick how much Vim you want |
| `:NvsAsk [question]` | Ask how to do something (also F1 at Stages 1-3, and `Space ?`) |
| `:NvsTutor` | The nvs.ide lessons |
| `:NvsAI on\|off\|status` | Turn local AI on or off, or see what's running |
| `:NvsAI backend llamacpp\|ollama\|openai` | Where models come from (default: built-in llama.cpp) |
| `:NvsModel` | Pick the model Ask and ghost text use |
| `:NvsModel pull <repo>[:quant]` | Download a GGUF from Hugging Face |
| `:NvsModel folder` | Open the models folder |
| `:NvsWelcome` | Choose your starting stage again |

### Local AI

nvs.ide runs llama.cpp's `llama-server` in router mode over a folder of GGUF
files: every model in the folder is listed, and the one a request names is
loaded on demand. The server starts the first time Ask or ghost text needs it,
listens only on `127.0.0.1`, and stops when you quit.

1. Install llama.cpp: `winget install llama.cpp`, `scoop install llama.cpp` or
   `brew install llama.cpp`. The CUDA, ROCm and Vulkan builds use your GPU.
2. Get a model and turn AI on:

   ```vim
   :NvsModel pull Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M
   :NvsAI on
   ```

   Or drop any `.gguf` into the folder `:NvsModel folder` opens.
3. Restart once so ghost text loads. `Alt+A` accepts a suggestion, `Alt+L`
   one line, `Alt+E` dismisses.

Coder models with fill-in-the-middle support (Qwen2.5-Coder, DeepSeek-Coder,
CodeLlama, StarCoder, CodeGemma) give the best ghost text. To use a server you
already run instead, `:NvsAI backend ollama` or `:NvsAI backend openai` with
`:NvsAI url <address>`. For a model on another machine, forward its port over
SSH and keep the local address.

## Layout

```
runtime/                LazyVim config + the nvs.ide layer (the Neovim half)
  lua/config/           LazyVim bootstrap, options, keymaps
  lua/nvs/              stages, coach, ask, ai (llama.cpp / Ollama / OpenAI), state
  lua/plugins/nvs.lua   plugins nvs.ide adds (minuet, blink.cmp tweaks)
  kb/ask.json           Ask's written answers, shared with the preview
  tutor/                :NvsTutor lessons
  colors/               necronomicon colour scheme
assets/                 the icon (png, and a multi-size ico for Windows)
docs/design.md          the design
docs/preview/           interactive mockup (build with scripts/build-preview.py)
tests/                  headless checks for the runtime
scripts/try.ps1         run the runtime next to your own config
```

## Tests

`tests/verify.lua` runs 28 headless checks against a sandboxed install: commands,
stage keymaps (and restoring LazyVim's own at Stage 4), saved state and its
migration, the lessons, and Ask. `tests/ai_live.lua` runs 11 more against a real
llama-server: Ask answered by a model, a Hugging Face download, and ghost text
wired to the server. Each file's header has the commands.

After editing `runtime/kb/ask.json`, the lessons or the icon, rebuild the
mockup with `python scripts/build-preview.py`.

## License

MIT. See [LICENSE](LICENSE). LazyVim is Apache-2.0, Neovim is Apache-2.0 plus
the Vim license, llama.cpp and Neovide are MIT.
