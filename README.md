# nvs.ide

**LazyVim with training wheels, for people leaving VS Code.** (`nvs.ide` is a working name.)

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
- **Local AI through Ollama**: Ask falls back to your model when the guide has
  no answer. Ghost text uses a small model for Copilot-style suggestions.
  Nothing leaves your machine.

The plan is a native window around Neovim (a Neovide fork) with VS Code's
workbench: explorer, settings screen, plugin browser and panels.
[docs/preview/index.html](docs/preview/index.html) is an interactive mockup of
it, and [docs/design.md](docs/design.md) is the design.

## Status

| Part | State |
|---|---|
| `runtime/`: LazyVim + stages, coach, Ask, lessons, Ollama | Works today in Neovide or a terminal |
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
| `:NvsOllama on\|off\|status\|model <name>\|url <url>` | Local AI settings |
| `:NvsWelcome` | Choose your starting stage again |

### Local AI

```vim
:NvsOllama on
:NvsOllama status
```

The default address is `http://localhost:11434`. If Ollama runs on another
machine, forward port 11434 over SSH and keep the default. Ask uses
`qwen2.5-coder:7b` and ghost text uses `qwen2.5-coder:1.5b`; change them with
`:NvsOllama model <name>`, or `complete_model` in the state file. Ghost text is
[minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim) and loads
after a restart. `Alt+A` accepts a suggestion.

## Layout

```
runtime/                LazyVim config + the nvs.ide layer (the Neovim half)
  lua/config/           LazyVim bootstrap, options, keymaps
  lua/nvs/              stages, coach, ask, ollama, state
  lua/plugins/nvs.lua   plugins nvs.ide adds (minuet, blink.cmp tweaks)
  kb/ask.json           Ask's written answers, shared with the preview
  tutor/                :NvsTutor lessons
  colors/               necronomicon colour scheme
docs/design.md          the design
docs/preview/           interactive mockup (build with scripts/build-preview.py)
tests/verify.lua        headless checks for the runtime
scripts/try.ps1         run the runtime next to your own config
```

## Tests

`tests/verify.lua` runs 24 headless checks against a sandboxed install: commands,
stage keymaps (and restoring LazyVim's own at Stage 4), saved state, the
lessons, and Ask. The file's header has the commands.

After editing `runtime/kb/ask.json` or the lessons, rebuild the mockup with
`python scripts/build-preview.py`.
