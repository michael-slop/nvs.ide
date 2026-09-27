# Extension fixtures

Offline test data for `tests/verify_vsx.lua` and `tests/verify_theme.lua`. Each folder
is named after an Open VSX id and holds what the tests read: `package.json`,
`files.txt` (the paths inside the real `.vsix`'s `extension/` folder, for
classification) and `fixture.vsix`, a small archive built by `make_vsix.lua` for the
install tests. Server entry points are replaced by `stub-server.js`, a minimal LSP
server; no extension's real code is included.

Copied from the published extensions (Open VSX, 2026-09-25), all MIT licensed:

| folder | files copied | source | licence |
|---|---|---|---|
| `Catppuccin.catppuccin-vsc` | `package.json`, `themes/mocha.json`, `themes/latte.json` | https://github.com/catppuccin/vscode (3.19.0) | MIT |
| `dbaeumer.vscode-eslint` | `package.json` | https://github.com/Microsoft/vscode-eslint (3.0.34) | MIT |
| `redhat.vscode-yaml` | `package.json` | https://github.com/redhat-developer/vscode-yaml (1.25.2026092308) | MIT |
| `esbenp.prettier-vscode` | `package.json` | https://github.com/prettier/prettier-vscode (12.4.0) | MIT |

`acme.generic-ls`, `acme.silent-ls` and `nvs.snippets-fixture` are made up for the tests.
