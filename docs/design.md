# nvs.ide design

nvs.ide is a stepping stone from VS Code to Neovim. It's stock Neovim running
LazyVim, with a layer of VS Code-style hand-holding that fades out as the user
learns, and eventually a native window with VS Code's workbench around it.

## Where it comes from

The original idea was to combine neovim/neovim and vscodium/vscodium. They can't
be merged as code, because **VSCodium contains no editor**: it's build scripts
and patches that repackage Microsoft's VS Code (Electron) without telemetry and
point it at the Open VSX registry. So each project does a different job:

| Project | What nvs.ide takes |
|---|---|
| neovim/neovim | The whole editing engine, unforked, embedded over its msgpack-RPC UI protocol |
| LazyVim/LazyVim | The plugin set and defaults: finder, explorer, completion, LSP, git, formatting |
| neovide/neovide | The Neovim bridge, keyboard and mouse handling and grid model, ported into the window (MIT) |
| vscodium/vscodium | The Open VSX registry, the no-telemetry policy and the licensing approach |

Most "VS Code features" are external servers speaking open protocols: language
features over LSP and debugging over DAP. Neovim speaks both. What's missing for
a VS Code user is the workbench and the hand-holding, and that's the product.

## The transition layer (runtime/, works today)

### Stages

`:NvsStage 1-4`, stored in `stdpath("data")/nvs-ide.json`.

| Stage | Files open in | VS Code shortcuts | Coach |
|---|---|---|---|
| 1 · VS Code keys | Insert mode; Esc stays there | Ctrl+S, Z, /, P, F, B, Shift+K, Shift+F, Shift+P, F1 | On |
| 2 · Hybrid | Insert mode; Esc gives Normal | Same set | On |
| 3 · Modal with safety net | Normal mode | Same set | On |
| 4 · Pure Neovim | Normal mode | None; LazyVim's own keys | Quiet |

`lua/nvs/stages.lua` records any mapping it replaces (LazyVim's Ctrl+/
terminal, its Insert-mode Esc) and restores it when the stage changes. A
first-run welcome asks "where are you coming from?" and picks the stage.

### Coach

`lua/nvs/coach.lua`. Each VS Code-style shortcut also shows the Vim way once in
a notification ("Ctrl+Shift+K deleted the line. In Normal mode: dd"). Runs of
six or more arrow presses suggest counts (6j). Frequency: every time, first
three times, once, or off. Silent at Stage 4.

### Ask

`lua/nvs/ask.lua`, answers in `kb/ask.json`.

- 77 written answers, each with the phrasings people use, the Vim keys, the VS
  Code keys and an optional Ex command for Try it.
- Matching: normalise words (synonyms such as "yank" to "copy", stop words
  removed), then score each phrasing by IDF-weighted overlap in both
  directions. No network, no model.
- Below the confidence threshold, if local AI is on, the question goes to
  the local model with the closest written answers as context. Any `:command` in the reply is
  offered through a picker and runs only when chosen.
- Opens with F1 (Stages 1 to 3), `Space ?` or `:NvsAsk <question>`.

### Lessons

`tutor/nvs-ide.tutor` runs in Neovim's own tutor engine (`:NvsTutor`). Nine
lessons for VS Code users; exercise lines are checked against
`nvs-ide.tutor.json` and flip from ✗ to ✓.

### Completion and local AI

- blink.cmp (LazyVim's default) with documentation shown automatically and
  inline ghost text for the selected item.
- minuet-ai.nvim for Copilot-style ghost text from the local model, loaded
  only when `:NvsAI on`. Alt+A accepts. On llama.cpp, nvs.ide builds the
  fill-in-the-middle prompt for the model family (Qwen, DeepSeek, CodeLlama,
  StarCoder, CodeGemma); Ollama applies its own template.
- `lua/nvs/ai.lua` has three backends, all spoken to through the
  OpenAI-compatible API with curl through `vim.system`:
  - **llamacpp (default):** nvs.ide starts llama.cpp's `llama-server` in router
    mode (`--models-dir`) on 127.0.0.1. Every GGUF in the models folder is listed
    and loaded on first use, up to `models_max` at once. This gives Ollama's
    "run any model" without Ollama. `:NvsModel pull owner/repo:quant` looks the
    file up through the Hugging Face API, downloads it, and restarts the server,
    because the router only scans the folder at start. The server starts lazily
    and stops on `VimLeavePre`.
  - **ollama:** an Ollama server, default `http://localhost:11434`.
  - **openai:** any other OpenAI-compatible server (LM Studio, vLLM, llamafile),
    with an optional API key read from an environment variable.
- A model on another machine is reached by forwarding its port over SSH, never
  by opening it on the network.

## The native window (Phase 1 onward)

```
+--------------------------------------------------------------+
|  nvs.ide shell  (Rust: winit + wgpu + swash, own renderer)   |
|  workbench chrome, palette, Settings, Plugins, Learn, Welcome|
+-----------+-----------------------------+--------------------+
            | msgpack-RPC (stdio)         | JSON-RPC (on demand)
+-----------v-----------+      +----------v---------------------+
|  nvim --embed          |<---->|  extension host (Node, optional)|
|  runtime/ (LazyVim +   |      |  subset of the vscode API,      |
|  nvs layer + bridge)   |      |  Open VSX extensions (not built)|
+------------------------+      +--------------------------------+
```

- The shell is its own crate, not a Neovide fork: Neovide's skia build needs
  the MSVC toolchain and prebuilt binaries this machine cannot use, so the
  window renders with wgpu and a swash glyph atlas instead. Neovide's Neovim
  bridge, event parser, grid model, keyboard translation and mouse handling
  are ported (MIT, `shell/LICENSE-NEOVIDE`).
- One renderer draws everything: Neovim's grids (`ext_multigrid`, floats by
  z-index) and the chrome, as cells in the same 8x12 pixel font, so the house
  font stays crisp. The cmdline, popup menu and messages stay in the grid,
  drawn by noice, blink and snacks; noice attaches its own in-process UI, so
  the shell parses those events and leaves them to it.
- `lua/nvs/bridge.lua` streams mode, buffers, cursor, branch, diagnostics,
  LSP clients, the stage and AI state to the shell with `rpcnotify`, plus the
  settings schema and the plugin list on request. Shell actions go back as
  Neovim commands and Lua calls, so everything stays scriptable.
- **Settings screen:** 12 categories and 56 settings that all do something in
  this runtime (the mockup's minimap, extension-host and workspace-scope rows
  were dropped rather than shown inert), searchable by Vim name, each showing
  the Lua or command it maps to. Values live in `nvs-settings.json`; every
  change regenerates `lua/nvs/settings.lua`, which `config/options.lua` loads
  after LazyVim's defaults so terminal Neovim gets the same settings. Import
  reads VS Code's `settings.json` and `keybindings.json` and reports what had
  no equivalent.
- **Plugins screen:** lazy.nvim's list (loaded, lazy, updates, what each one
  covers from VS Code) and LazyVim's extras, toggled the way `:LazyExtras`
  does it. Open VSX is not built.
- **Extension host:** not built. The design stands: Tier 1 declarative
  contributions convert at install time; Tier 2 providers run in Node as a
  virtual LSP server; Tier 3 webviews are deferred.

## Budgets

Re-based in the 2026-09-25 review after measuring: LazyVim alone takes longer
than the original 150 ms, and a GPU device takes about 300 ms to create.

- Window visible under 300 ms warm, editable under 600 ms warm.
  Measured on pHub (RTX 5090, Vulkan, release build): window visible at
  426 ms, first Neovim flush at 506 ms.
- Idle memory under 200 MB for shell plus Neovim (measured: 130 MB + 54 MB).
- The shell never blocks on Neovim: the bridge runs on its own thread, the
  editor model on another, subprocess work (ripgrep, git) on task threads.

## Look

The necronomicon palette (also `runtime/colors/necronomicon.lua`),
BigBlueTerm437 Nerd Font Mono, Win98 bevels, no rounded corners, icons drawn
rather than emoji.

## Phases

0. Design preview and the runtime (done)
1. Shell: bridge, renderer, workbench layout, palette (done)
2. Panels: Problems, Output, Search, Source control (done); Outline, Debug and
   a native terminal panel are not built (the terminal opens in the grid)
3. Settings, Plugins, Learn and Welcome screens (done); Ask stays in the grid
4. Extension host (not started)
5. Packaging: a release build with the icon, a Start-menu shortcut and an
   `nvs` launcher exist; no installer yet

## License

MIT (see LICENSE). nvs.ide is a community tool: forks, extra Ask answers and
new lessons are welcome.
