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
- **Markdown renderer**: headings, tables, checkboxes and code blocks render
  right in the editor (`Space u m` toggles), and `Space c p` opens a live
  browser preview that follows your cursor.
- **Local AI, any model, no Ollama required**: nvs.ide runs llama.cpp itself and
  loads any GGUF model, including ones it downloads from Hugging Face for you. Ask
  falls back to the model when the guide has no answer, and ghost text uses it
  for Copilot-style suggestions. Ollama and OpenAI-compatible servers (LM
  Studio, vLLM, llamafile) work too. Nothing leaves your machine.

Around it is **the window**: a native Rust shell (`shell/`) that draws VS Code's
workbench around Neovim's grid: activity bar, explorer, search, source control,
tabs, a bottom panel with problems and output, a status bar, a command palette
(`Ctrl+Shift+P`), and native Settings, Plugins, Learn and Welcome screens.
Neovim draws the text; the shell draws everything else, in the same pixel font.
[docs/preview/index.html](docs/preview/index.html) is the interactive mockup it
was built from, and [docs/design.md](docs/design.md) is the design.

## Status

| Part | State |
|---|---|
| `runtime/`: LazyVim + stages, coach, Ask, lessons, local AI | Works in the window, in Neovide, or in a terminal |
| `shell/`: the native window (Rust, wgpu, own renderer) | Works: workbench, palette, Settings, Plugins, Learn, Welcome |
| Settings screen | 59 settings in 13 categories, writes `lua/nvs/settings.lua`, imports VS Code's `settings.json` and `keybindings.json` |
| Plugins screen | lazy.nvim's list, LazyVim's extras, and VS Code extensions from Open VSX (Browse, install, enable, uninstall) |
| VS Code extensions | Themes and snippets convert at install; extensions that ship a language server run under Neovim's LSP client; the rest run in a Node extension host (Prettier formats through it). Webview extensions are not supported. See [docs/extensions.md](docs/extensions.md) |
| Packaging | Windows zip and per-user installer (`scripts/package.ps1`), Linux tarball (`scripts/package.sh`), each with Neovim, ripgrep and the house font bundled; CI on Windows and Linux and tagged releases on GitHub Actions |
| Debugger view, workspace-scoped settings, macOS build | Not built; `Space d` works once the dap.core extra is on |

## Run it

Everything runs as a separate Neovim app (`NVIM_APPNAME=nvs-ide`), so your own
config, plugins and data are left alone.

### Install

Pushing a `v*` tag builds these and attaches them to a GitHub release
(`.github/workflows/release.yml`); until the first tag, build them locally with
`scripts\package.ps1` or `scripts/package.sh` (below).

#### Windows

- **`nvs.ide-<version>-setup.exe`** installs for the current user, no admin,
  into `%LOCALAPPDATA%\Programs\nvs.ide`, with a Start-menu shortcut and, if you
  tick it, `nvs` on your PATH (`nvs .` opens a folder from any terminal). It
  looks for git, a C compiler and tree-sitter and prints the winget commands
  for the ones you don't have. Uninstalling removes only the install folder
  (including what LazyVim wrote into its `runtime\`, such as `lazyvim.json`);
  your data folder (`%LOCALAPPDATA%\nvs-ide-data`: plugins, models, settings)
  stays.
- **`nvs.ide-<version>-windows-x64.zip`** is the same files without the
  installer: unzip anywhere and run `nvs-ide.exe` (or `nvs.cmd`).

Both bundle Neovim 0.12, ripgrep and the house font. You still need git (plugins
are cloned with it), a C compiler and the tree-sitter CLI (syntax parsers):
`winget install Git.Git BrechtSanders.WinLibs.POSIX.UCRT tree-sitter.tree-sitter-cli`.
Optional: fd (faster file pickers), Node.js (VS Code extensions) and llama.cpp
(local AI).

#### Linux

**`nvs.ide-<version>-linux-x86_64.tar.gz`** holds the same files for x86_64 Linux
with glibc 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora 36, Arch and later).
Unpack it anywhere and run `./install.sh`: it links `nvs` and `nvs-ide` into
`~/.local/bin` and adds nvs.ide to the application menu, with no root and
nothing outside your home folder (`./install.sh --uninstall` takes exactly that
back out). Or skip it and run `./nvs-ide` from the folder.

```sh
mkdir -p ~/.local/opt
tar -xzf nvs.ide-<version>-linux-x86_64.tar.gz -C ~/.local/opt   # any folder works
~/.local/opt/nvs.ide/install.sh
nvs .
```

It bundles Neovim 0.12, ripgrep and the house font. The window needs a Vulkan or
OpenGL driver (Mesa's are fine) under Wayland or X11. You still need git, a C
compiler, `unzip` (VS Code extensions are zip files) and tree-sitter 0.26.1 or
newer: `sudo pacman -S git base-devel unzip tree-sitter-cli` on Arch;
`sudo apt install git build-essential unzip` on Debian and Ubuntu, plus
tree-sitter from its [releases](https://github.com/tree-sitter/tree-sitter/releases)
(Ubuntu 24.04's package is 0.20, too old). `:checkhealth nvs` names anything
missing, with the command for your distribution.

Your data is in `~/.local/share/nvs-ide` (plugins, models, settings) and the
config link in `~/.config/nvs-ide`; uninstalling leaves both.

#### Building it
 `nvs-ide --version` says which runtime and Neovim it found, and
`:checkhealth nvs` inside the editor lists all of the above.
`scripts\package.ps1 -Version x.y.z` builds both Windows files from a checkout
(the setup exe needs Inno Setup 6), and `scripts/package.sh x.y.z` the Linux
tarball. Or build the window yourself:

```powershell
git clone https://github.com/michael-slop/nvs.ide
cd nvs.ide\shell
cargo build --release        # the window: shell\target\release\nvs-ide.exe
.\target\release\nvs-ide.exe # or double-click it; nvs-ide --help lists the options
```

On Linux the same, with `./target/release/nvs-ide`; the build needs only Rust
and a C compiler, since the window loads X11, Wayland and Vulkan at run time.

The first start links the app's config folder to `runtime/`, installs LazyVim
and its plugins (a minute), and shows the Welcome screen to pick a stage.

Without the window:

```powershell
.\scripts\try.ps1            # Neovide
.\scripts\try.ps1 -Terminal  # nvim in this terminal
```

**Needs:** Neovim 0.11 or newer (0.12 tested), git, a C compiler, curl, and the
`tree-sitter` CLI for LazyVim's syntax parsers; ripgrep for the Search view.
fd and lazygit are recommended. To build the window: Rust stable (the GNU
toolchain works on Windows, with `rustup override set stable-x86_64-pc-windows-gnu`
in `shell\`; no MSVC needed) and a Vulkan, DirectX 12 or OpenGL driver. On Windows, run `git config --global core.longpaths true` if a plugin
fails to clone.

### The window

| Key | Does |
|---|---|
| `Ctrl+Shift+P` | Command palette: commands, `:` Ex commands, `@` files, `/` search the file |
| `Ctrl+B`, `Ctrl+\`` | Toggle the sidebar (stages 1 to 3) and the bottom panel |
| `Ctrl+Shift+E` `F` `G` `M` | Explorer, Search, Source control, Problems, with the keyboard |
| `Ctrl+,` `Ctrl+Shift+X` | Settings, Plugins |
| `j` `k` `Enter` `h` `l` `/` `Esc` | Every list and screen moves like Vim; Esc goes back to the editor |

Every setting on the Settings screen shows the Lua or command it maps to, and
`Import from VS Code` reads your `settings.json` and `keybindings.json` and says
what it could and could not carry over.

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
| `:NvsCoach always\|three\|once\|off`, `:NvsCoach ghost on\|off` | How often hints repeat; ghost text on or off |
| `:NvsSettings` | The Settings screen in the window; in a terminal, the generated `settings.lua` |

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
  lua/nvs/              stages, coach, ask, ai (llama.cpp / Ollama / OpenAI), state,
                        prefs (the settings schema), plugins (the Plugins screen's data),
                        bridge (streams state to the window)
  lua/plugins/nvs.lua   plugins nvs.ide adds and the settings that reach plugin options
  kb/ask.json           Ask's written answers, shared with the preview
  tutor/                :NvsTutor lessons
  colors/               necronomicon colour scheme
shell/                  the window (Rust)
  src/bridge/           nvim --embed, msgpack-RPC, the UI protocol (ported from Neovide)
  src/editor/           grids, windows, styles, cursor
  src/renderer/         wgpu, glyph atlas, pixel icons, one quad pipeline for text and chrome
  src/ui/               cell-based widgets: lists, fields, tabs, buttons, bevels
  src/workbench/        activity bar, sidebar views, palette, panel, status bar, screens
  tests/attach.rs       headless end-to-end: attach, type, quit
assets/                 the icon (png, and a multi-size ico for Windows)
docs/design.md          the design
docs/preview/           interactive mockup (build with scripts/build-preview.py)
tests/                  headless checks for the runtime
scripts/try.ps1         run the runtime next to your own config, without the window
scripts/package.*       release packages: .ps1 for Windows, .sh for Linux
installer/              the Inno Setup script; linux/ has the launcher, menu entry and install.sh
```

## Tests

```powershell
.\tests\run.ps1                      # the runtime, in a sandbox: verify.lua + verify_ui.lua
cd shell; cargo test                 # the window: unit tests and the attach test
```

On Linux and macOS, `bash tests/run.sh` is the same runner. CI runs both halves
on Windows and Linux, and on Linux also takes an offscreen screenshot of the
window under Xvfb and fails it if the frame is blank.

`tests/verify.lua` checks startup: commands, stage keymaps (and restoring
LazyVim's own at Stage 4), saved state and its migration, the lessons, Ask, and
the Markdown renderer. `tests/verify_ui.lua` runs inside Neovim's main loop and
types like a person: Insert-mode behaviour at each stage, Ask's window, the
explorer and search keys, the tutor, settings validation, Ask's answers and the
theme. `tests/ai_live.lua` runs against a real llama-server: Ask answered by a
model, a Hugging Face download, ghost text, and stopping the server's process
tree. `tests/verify_health.lua` runs `:checkhealth nvs` headless and checks it
reports every tool, the config link, the data folder and the window. Each file's
header has the commands.

After editing `runtime/kb/ask.json`, the lessons or the icon, rebuild the
mockup with `python scripts/build-preview.py`.

## Security

See [SECURITY.md](SECURITY.md) to report a vulnerability privately.

## License

MIT. See [LICENSE](LICENSE). LazyVim is Apache-2.0, Neovim is Apache-2.0 plus
the Vim license, llama.cpp is MIT. The window's Neovim bridge, keyboard and
mouse handling are ported from [Neovide](https://github.com/neovide/neovide)
(MIT, `shell/LICENSE-NEOVIDE`).
