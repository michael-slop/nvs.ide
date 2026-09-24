<#
.SYNOPSIS
  Run the nvs.ide runtime (LazyVim + the nvs.ide layer) next to your own Neovim config.

.DESCRIPTION
  Links this repo's runtime/ folder as the Neovim app "nvs-ide" (NVIM_APPNAME), then
  starts Neovide with it. Your normal nvim config, plugins and data are not touched:
  nvs-ide gets its own config, data and state folders.

  The first start downloads LazyVim and its plugins, which takes a minute.

.PARAMETER Terminal
  Start nvim in this terminal instead of Neovide.
#>
param([switch]$Terminal)
$ErrorActionPreference = 'Stop'

$runtime = (Resolve-Path (Join-Path $PSScriptRoot '..\runtime')).Path
$env:NVIM_APPNAME = 'nvs-ide'
$config = (& nvim --headless --clean -c 'lua io.write(vim.fn.stdpath("config"))' -c q 2>&1 | Out-String).Trim()

if (Test-Path $config) {
  $item = Get-Item $config -Force
  if ($item.LinkType -ne 'Junction' -or $item.Target -notcontains $runtime) {
    throw "$config already exists and isn't a link to $runtime. Move it aside and run this again."
  }
} else {
  New-Item -ItemType Junction -Path $config -Target $runtime | Out-Null
  Write-Host "Linked $config -> $runtime"
}

$missing = @('git', 'rg', 'fd', 'lazygit', 'tree-sitter', 'curl') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing) {
  Write-Warning ("Missing tools: {0}. LazyVim works without them, but some features won't (tree-sitter is needed for syntax parsers, lazygit for <leader>gg)." -f ($missing -join ', '))
}
if ((& git config --global core.longpaths) -ne 'true') {
  Write-Warning 'Some plugins have very long file paths. If a plugin fails to clone, run: git config --global core.longpaths true'
}

if ($Terminal -or -not (Get-Command neovide -ErrorAction SilentlyContinue)) {
  & nvim @args
} else {
  & neovide @args
}
