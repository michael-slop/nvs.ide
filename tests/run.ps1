<#
.SYNOPSIS
  Run the nvs.ide runtime checks in a sandbox that never touches your own Neovim config.

.DESCRIPTION
  Points XDG_CONFIG_HOME/DATA/STATE/CACHE at a sandbox folder, links the sandbox's
  nvs-ide config to this repo's runtime/ (a junction, so edits are live), installs the
  plugins on first use, then runs:
    tests/verify.lua     startup checks (runs before the main loop)
    tests/verify_ui.lua  main-loop checks (modes, keys, windows; runs inside the loop)
  Every result line starts with PASS or FAIL. Exit code is the FAIL count.

.PARAMETER Sandbox
  Sandbox folder. Default: $env:TEMP\nvs-sb. Keep it SHORT: Neovim's byte-code cache
  encodes full paths into file names and a deep folder pushes them past MAX_PATH.

.PARAMETER ShareFrom
  Another sandbox whose installed plugins (data\nvs-ide-data\lazy and \mason) this
  sandbox links to instead of downloading again. For running several sandboxes at once.

.PARAMETER Only
  'core', 'ui' or 'both' (default).
#>
param(
  [string]$Sandbox = (Join-Path $env:TEMP 'nvs-sb'),
  [string]$ShareFrom = '',
  [ValidateSet('core', 'ui', 'both')][string]$Only = 'both',
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $repo 'runtime'

foreach ($d in 'config', 'data', 'state', 'cache') { New-Item -ItemType Directory -Force (Join-Path $Sandbox $d) | Out-Null }
$env:XDG_CONFIG_HOME = Join-Path $Sandbox 'config'
$env:XDG_DATA_HOME = Join-Path $Sandbox 'data'
$env:XDG_STATE_HOME = Join-Path $Sandbox 'state'
$env:XDG_CACHE_HOME = Join-Path $Sandbox 'cache'
$env:NVIM_APPNAME = 'nvs-ide'
# Tells runtime/lua/plugins/nvs.lua to skip tool and parser downloads: they spawn child
# processes that keep stdout open (the runner would wait on them) and would collide
# across sandboxes that share one plugin folder.
$env:NVS_TEST = '1'

$config = Join-Path $env:XDG_CONFIG_HOME 'nvs-ide'
if (Test-Path $config) {
  $item = Get-Item $config -Force
  if ($item.LinkType -ne 'Junction') { throw "$config exists and is not a junction to $runtime; move it aside." }
} else {
  New-Item -ItemType Junction -Path $config -Target $runtime | Out-Null
}

$data = Join-Path $env:XDG_DATA_HOME 'nvs-ide-data'
New-Item -ItemType Directory -Force $data | Out-Null
if ($ShareFrom) {
  foreach ($sub in 'lazy', 'mason', 'site') {
    $link = Join-Path $data $sub
    $target = Join-Path $ShareFrom "data\nvs-ide-data\$sub"
    if (-not (Test-Path $link) -and (Test-Path $target)) {
      New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
  }
}
if (-not (Test-Path (Join-Path $data 'lazy\LazyVim'))) {
  if (-not $Quiet) { Write-Host "Installing plugins into $data (first run)..." }
  & nvim --headless '+Lazy! sync' +qa 2>&1 | Out-Null
}

# Every run starts from the same saved state: Stage 2, welcome already shown.
Set-Content -Path (Join-Path $data 'nvs-ide.json') -Value '{"stage":2,"welcomed":true}' -NoNewline

# The UI checks must run INSIDE the main loop (after VimEnter, via a timer) so that
# BufEnter/startinsert, feedkeys and windows behave as they do for a person. No double
# quotes in this command: PowerShell strips them from native arguments.
$uiEntry = 'autocmd VimEnter * ++once lua vim.defer_fn(function() local ok, e = pcall(dofile, [[tests/verify_ui.lua]]) if not ok then io.write([[FAIL ui: harness error: ]] .. tostring(e) .. string.char(10)) io.flush() os.exit(3) end end, 800)'
$errFile = Join-Path $Sandbox 'run-stderr.log'

Push-Location $repo
# Neovim writes notifications to stderr; that must not be a terminating error here.
$ErrorActionPreference = 'Continue'
try {
  $lines = @()
  if ($Only -ne 'ui') {
    $lines += (& nvim --headless -c 'luafile tests/verify.lua' 2> $errFile | Out-String) -split "`r?`n"
  }
  if ($Only -ne 'core') {
    $lines += (& nvim --headless --cmd 'let g:nvs_test_ui = 1' -c $uiEntry 2>> $errFile | Out-String) -split "`r?`n"
  }
} finally { Pop-Location }

$results = $lines | Where-Object { $_ -match '^(PASS|FAIL) ' }
$fails = @($results | Where-Object { $_ -like 'FAIL *' })
if (-not $Quiet) { $results | ForEach-Object { if ($_ -like 'FAIL *') { Write-Host $_ -ForegroundColor Red } else { Write-Host $_ } } }
$other = @($lines | Where-Object { $_ -and $_ -notmatch '^(PASS|FAIL) ' })
if (Test-Path $errFile) { $other += Get-Content $errFile | Where-Object { $_ -and $_ -notmatch '^Stage \d: ' } }
if ($other -and -not $Quiet) { Write-Host '--- other output ---'; $other | Select-Object -First 20 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray } }
Write-Host ("{0} passed, {1} failed" -f (@($results).Count - $fails.Count), $fails.Count)
exit $fails.Count
