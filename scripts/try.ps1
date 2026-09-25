<#
.SYNOPSIS
  Run the nvs.ide runtime (LazyVim + the nvs.ide layer) WITHOUT the nvs.ide window.

.DESCRIPTION
  Links this repo's runtime/ folder as the Neovim app "nvs-ide" (NVIM_APPNAME), then
  starts Neovide with it. Your normal nvim config, plugins and data are not touched:
  nvs-ide gets its own config, data and state folders.

  The nvs.ide window (shell\target\release\nvs-ide.exe, built with cargo) does the same
  link on its own first start; use it instead when you want the workbench.

  The first start downloads LazyVim and its plugins, which takes a minute.

.PARAMETER Terminal
  Start nvim in this terminal instead of Neovide.

.PARAMETER Shortcut
  Create an "nvs.ide" shortcut with the necronomicon icon (Start menu by default)
  that runs this script, then exit.

.PARAMETER ShortcutPath
  Where to write the shortcut, when -Shortcut is given.
#>
param(
  [switch]$Terminal,
  [switch]$Shortcut,
  [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Programs')) 'nvs.ide.lnk')
)
$ErrorActionPreference = 'Stop'

if ($Shortcut) {
  $shell = New-Object -ComObject WScript.Shell
  $lnk = $shell.CreateShortcut($ShortcutPath)
  $exe = Join-Path $PSScriptRoot '..\shell\target\release\nvs-ide.exe'
  if (Test-Path $exe) {
    # The window, once it has been built (cd shell; cargo build --release).
    $lnk.TargetPath = (Resolve-Path $exe).Path
    $lnk.Arguments = ''
    $lnk.IconLocation = (Resolve-Path $exe).Path + ',0'
  } else {
    $lnk.TargetPath = (Get-Command powershell.exe).Source
    $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $lnk.IconLocation = (Resolve-Path (Join-Path $PSScriptRoot '..\assets\nvs.ide.ico')).Path + ',0'
  }
  $lnk.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
  $lnk.Description = 'nvs.ide: LazyVim with training wheels'
  $lnk.Save()
  Write-Host "Created $ShortcutPath"
  return
}

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
