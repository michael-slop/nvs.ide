# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: on this repo, go to
**Security → Report a vulnerability**. Don't open a public issue for them.

## What nvs.ide does and doesn't do

- **Local AI stays local.** The built-in llama.cpp server listens on
  `127.0.0.1` only and stops when the editor quits. nvs.ide never opens a port
  to the network. To use a model on another machine, forward its port over
  SSH.
- **Model output never runs by itself.** When Ask gets an answer from a model,
  any `:command` it suggests only runs after you pick it from a list.
- **Downloads go where you point them.** `:NvsModel pull` fetches from Hugging
  Face over HTTPS into your models folder. Plugins come from GitHub through
  lazy.nvim, and language tools come through Mason, the same way as in any
  LazyVim setup.
- **No telemetry.** nvs.ide sends nothing anywhere.
- **API keys aren't stored.** For an OpenAI-compatible server that needs a key,
  nvs.ide reads it from an environment variable you name, and never writes it to
  its settings file.
