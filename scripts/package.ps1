<#
.SYNOPSIS
  Build the nvs.ide Windows package: a zip and, with Inno Setup, a setup exe under dist\.

.DESCRIPTION
  1. cargo build --release in shell\. When WinLibs mingw64 is installed the winget way it
     goes on PATH and, unless RUSTUP_TOOLCHAIN is already set, the build uses the GNU
     toolchain (stable-x86_64-pc-windows-gnu) that links with it; otherwise the default
     toolchain (MSVC on most machines) builds.
  2. Stage dist\nvs.ide\: nvs-ide.exe, runtime\ (as in git, nothing generated), nvs.cmd,
     LICENSE, LICENSE-NEOVIDE, README.md, fonts\ (the house font, BigBlueTerm437 Nerd Font
     Mono from Nerd Fonts v3.5.1, CC BY-SA 4.0, with its licence and a NOTICE; checked
     against a pinned sha256) and, unless -NoBundle, nvim\ (Neovim v0.12.1,
     Apache-2.0) and rg\ (ripgrep 15.2.0, MIT). Both come from their GitHub releases into
     dist\cache\ and are checked by running them; ripgrep's zip is checked against the
     .sha256 file published next to it.
  3. dist\nvs.ide-<version>-windows-x64.zip, and dist\nvs.ide-<version>-setup.exe from
     installer\nvs-ide.iss when ISCC.exe (Inno Setup 6) is found.

.PARAMETER Version
  x.y.z, a leading v is dropped. Goes into the file names and the installer.

.PARAMETER NoBundle
  Leave Neovim and ripgrep out; the package then needs both on PATH. The files are named
  nvs.ide-<version>-nobundle-windows-x64.zip and nvs.ide-<version>-nobundle-setup.exe, so
  they never overwrite (or pass for) the bundled ones.

.PARAMETER NoBuild
  Reuse shell\target\release\nvs-ide.exe instead of building it.
#>
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [switch]$NoBundle,
  [switch]$NoBuild
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Windows PowerShell (powershell.exe) runs on .NET Framework, whose ZipFile writes entry
# names with backslashes unless this switch is off (a 4.6.1 retargeting change; pwsh's
# .NET always writes '/'). The zip spec (APPNOTE 4.4.17) wants '/', and macOS and Linux
# unzip a backslash name as one file called 'nvs.ide\runtime\init.lua'. .NET reads the
# switch once, on first use, so it is set before any ZipFile call.
[System.AppContext]::SetSwitch('Switch.System.IO.Compression.ZipFile.UseBackslash', $false)

$Version = $Version.TrimStart('v')
if ($Version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') {
  throw "Version must look like 1.2.3 (or 1.2.3-rc1), not '$Version'"
}

$NvimVersion = 'v0.12.1'
$NvimUrl = "https://github.com/neovim/neovim/releases/download/$NvimVersion/nvim-win64.zip"
$RgVersion = '15.2.0'
$RgAsset = "ripgrep-$RgVersion-x86_64-pc-windows-msvc"
$RgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/$RgVersion/$RgAsset.zip"
# The house font: pinned to the hash GitHub and Nerd Fonts' SHA-256.txt both publish.
$NfVersion = 'v3.5.1'
$NfSha256 = '5c2589a37394459fe2207a6e46ccb5c37a978c51c6a5a2f92985a1356be27846'
$FontFile = 'BigBlueTerm437NerdFontMono-Regular.ttf'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$shell = Join-Path $repo 'shell'
$dist = Join-Path $repo 'dist'
$stage = Join-Path $dist 'nvs.ide'
$cache = Join-Path $dist 'cache'
New-Item -ItemType Directory -Force $dist, $cache | Out-Null

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Get-Cached($url, $name) {
  $path = Join-Path $cache $name
  if (-not (Test-Path $path)) {
    Step "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
  }
  return $path
}

function Expand-Fresh($zip, $dir) {
  if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
}

# 1. The window -----------------------------------------------------------------------
$exe = Join-Path $shell 'target\release\nvs-ide.exe'
if ($NoBuild) {
  if (-not (Test-Path $exe)) { throw "-NoBuild, but $exe does not exist" }
  Step "Using the existing $exe"
} else {
  $winlibs = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.UCRT_*\mingw64\bin" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($winlibs) {
    $env:PATH = "$($winlibs.FullName);$env:PATH"
    if (-not $env:RUSTUP_TOOLCHAIN) { $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu' }
  }
  Step "cargo build --release in $shell"
  Push-Location $shell
  try {
    & cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
  } finally { Pop-Location }
}
$cargoVersion = (Select-String -Path (Join-Path $shell 'Cargo.toml') -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
if ($cargoVersion -ne $Version) {
  Write-Warning "Packaging as $Version, but shell\Cargo.toml says ${cargoVersion}; nvs-ide --version will print ${cargoVersion}. Bump Cargo.toml before tagging a release."
}

# 2. Staging ---------------------------------------------------------------------------
Step "Staging $stage"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe (Join-Path $stage 'nvs-ide.exe')

# runtime\ as it is in git: the files lazy.nvim and the Settings screen write into a
# checkout (gitignored) must not ship, nor anything a builder left behind.
Copy-Item -Recurse (Join-Path $repo 'runtime') (Join-Path $stage 'runtime')
$generated = @('lazy-lock.json', 'lazyvim.json', 'lua\nvs\settings.lua')
foreach ($g in $generated) {
  $p = Join-Path $stage "runtime\$g"
  if (Test-Path $p) { Remove-Item -Force $p }
}
if (Test-Path (Join-Path $repo '.git')) {
  foreach ($f in @(& git -C $repo ls-files --others --ignored --exclude-standard runtime)) {
    $p = Join-Path $stage ($f -replace '/', '\')
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
  }
}
Get-ChildItem (Join-Path $stage 'runtime') -Recurse -Directory -Force |
  Where-Object { $_.Name -in @('node_modules', '__pycache__', '.git') } |
  ForEach-Object { if (Test-Path $_.FullName) { Remove-Item -Recurse -Force $_.FullName } }

# nvs.cmd: the launcher from a dev machine's bin\, rewritten to find the exe next to itself.
$nvsCmd = @(
  '@echo off',
  'rem nvs: start nvs.ide (the native window around Neovim + LazyVim) from any folder.',
  'rem   nvs                 open the current folder',
  'rem   nvs file.txt        open a file',
  'rem   nvs --help          every option',
  'rem The exe sits next to this script; the installer''s "add nvs to PATH" task puts this folder on PATH.',
  'set "NVS_EXE=%~dp0nvs-ide.exe"',
  'if not exist "%NVS_EXE%" (',
  '  echo nvs-ide.exe is missing next to %~f0',
  '  exit /b 1',
  ')',
  'start "" "%NVS_EXE%" %*'
)
[System.IO.File]::WriteAllText((Join-Path $stage 'nvs.cmd'), (($nvsCmd -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)

Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $stage 'LICENSE')
Copy-Item (Join-Path $shell 'LICENSE-NEOVIDE') (Join-Path $stage 'LICENSE-NEOVIDE')
Copy-Item (Join-Path $repo 'README.md') (Join-Path $stage 'README.md')

# The house font in fonts\, which nvs-ide loads from next to itself (scripts/package.sh
# does the same for Linux). Nerd Fonts publishes it as a .tar.xz; .NET cannot read xz, the
# tar.exe Windows ships (bsdtar with liblzma) can. Git's GNU tar would read C: as a host.
Step "Bundling the house font (Nerd Fonts $NfVersion, BigBlueTerminal)"
$archive = Get-Cached "https://github.com/ryanoasis/nerd-fonts/releases/download/$NfVersion/BigBlueTerminal.tar.xz" "BigBlueTerminal-$NfVersion.tar.xz"
$actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $NfSha256) {
  Remove-Item -Force $archive
  throw "BigBlueTerminal.tar.xz sha256 $actual, expected $NfSha256. The download was deleted; run again."
}
$fonts = Join-Path $stage 'fonts'
New-Item -ItemType Directory -Force $fonts | Out-Null
& "$env:SystemRoot\System32\tar.exe" -xf $archive -C $fonts $FontFile 'LICENSE.TXT' 'README.md'
if ($LASTEXITCODE -ne 0) { throw "tar.exe could not extract $archive" }
Move-Item (Join-Path $fonts 'LICENSE.TXT') (Join-Path $fonts 'LICENSE-BigBlueTerminal.txt')
Move-Item (Join-Path $fonts 'README.md') (Join-Path $fonts 'README-NerdFonts.md')
$notice = @(
  "$FontFile is BigBlue Terminal by VileR (https://int10h.org), (c) 2015, licensed under",
  'the Creative Commons Attribution-ShareAlike 4.0 International License',
  "(LICENSE-BigBlueTerminal.txt), as patched by Nerd Fonts $NfVersion",
  '(https://github.com/ryanoasis/nerd-fonts). It is unmodified from Nerd Fonts'' release',
  'archive BigBlueTerminal.tar.xz; README-NerdFonts.md, from the same archive, lists the',
  'licences of the icon sets the patch adds. nvs-ide loads it from this folder, so it does',
  'not need to be installed.'
)
[System.IO.File]::WriteAllText((Join-Path $fonts 'NOTICE.txt'), (($notice -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)

if (-not $NoBundle) {
  Step "Bundling Neovim $NvimVersion"
  $zip = Get-Cached $NvimUrl "nvim-win64-$NvimVersion.zip"
  $x = Join-Path $cache "nvim-$NvimVersion"
  Expand-Fresh $zip $x
  Move-Item (Join-Path $x 'nvim-win64') (Join-Path $stage 'nvim')
  $v = @(& (Join-Path $stage 'nvim\bin\nvim.exe') --version)[0]
  if ($v -notmatch ('^NVIM ' + [regex]::Escape($NvimVersion) + '\b')) { throw "bundled nvim.exe says '$v', expected NVIM $NvimVersion" }
  Write-Host "    $v"

  Step "Bundling ripgrep $RgVersion"
  $zip = Get-Cached $RgUrl "$RgAsset.zip"
  $sha = Get-Cached "$RgUrl.sha256" "$RgAsset.zip.sha256"
  $expected = ([regex]::Match((Get-Content $sha -Raw), '[0-9a-fA-F]{64}')).Value.ToLower()
  $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if (-not $expected -or $expected -ne $actual) {
    Remove-Item -Force $zip
    throw "ripgrep zip checksum mismatch: expected '$expected', got '$actual'. The download was deleted; run again."
  }
  $x = Join-Path $cache "rg-$RgVersion"
  Expand-Fresh $zip $x
  $src = Join-Path $x $RgAsset
  $rgdir = Join-Path $stage 'rg'
  New-Item -ItemType Directory -Force $rgdir | Out-Null
  Copy-Item (Join-Path $src 'rg.exe') $rgdir
  Get-ChildItem $src -File | Where-Object { $_.Name -match '^(COPYING|LICENSE.*|UNLICENSE)$' } | Copy-Item -Destination $rgdir
  $v = @(& (Join-Path $rgdir 'rg.exe') --version)[0]
  if ($v -notmatch ('^ripgrep ' + [regex]::Escape($RgVersion) + '\b')) { throw "bundled rg.exe says '$v', expected ripgrep $RgVersion" }
  Write-Host "    $v"
}

# 3. Zip and installer ------------------------------------------------------------------
# A -NoBundle package is a different thing and gets a different name.
$variant = if ($NoBundle) { '-nobundle' } else { '' }
$zipOut = Join-Path $dist "nvs.ide-$Version$variant-windows-x64.zip"
Step "Writing $zipOut"
if (Test-Path $zipOut) { Remove-Item -Force $zipOut }
# .NET's zip writer, not Compress-Archive (which writes backslash names in Windows
# PowerShell and has no setting for it); the UseBackslash switch above makes this one
# write '/' in both PowerShell editions. The prefix is the folder name, nvs.ide/.
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipOut, [System.IO.Compression.CompressionLevel]::Optimal, $true)
# Read it back: every name under nvs.ide/ with '/' only, or the zip is wrong.
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipOut)
try {
  $names = @($archive.Entries | ForEach-Object { $_.FullName })
} finally { $archive.Dispose() }
$badNames = @($names | Where-Object { $_.Contains('\') -or -not $_.StartsWith('nvs.ide/') })
if ($names.Count -eq 0 -or $badNames.Count -gt 0) {
  Remove-Item -Force $zipOut
  throw ("{0} has {1} entries and {2} bad names (backslash or not under nvs.ide/), e.g. '{3}'; deleted" -f $zipOut, $names.Count, $badNames.Count, ($badNames | Select-Object -First 1))
}
Write-Host "    $($names.Count) entries, all under nvs.ide/ with forward slashes"

$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
  foreach ($c in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
    if ($c -and (Test-Path $c)) { $iscc = $c; break }
  }
}
$setupBase = "nvs.ide-$Version$variant-setup"
$setup = Join-Path $dist "$setupBase.exe"
if ($iscc) {
  Step "Building $setup with $iscc"
  # /F overrides the script's OutputBaseFilename (iscc /? lists it), so the variant lands in the name.
  $isccArgs = @('/Qp', "/DAppVersion=$Version", "/DSourceDir=$stage", "/O$dist", "/F$setupBase")
  if (-not $NoBundle) { $isccArgs += '/DBundled=1' }
  & $iscc @isccArgs (Join-Path $repo 'installer\nvs-ide.iss')
  if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
  if (-not (Test-Path $setup)) { throw "ISCC finished but $setup is missing (the /F name above is what it should have written)" }
} else {
  Write-Warning "ISCC.exe not found, so no setup exe. Install Inno Setup 6 (winget install JRSoftware.InnoSetup) and run again."
}

Step "Done"
foreach ($f in @($zipOut, $setup)) {
  if (Test-Path $f) { Write-Host ("    {0,-60} {1,8:N1} MB" -f (Split-Path $f -Leaf), ((Get-Item $f).Length / 1MB)) }
}
Write-Host "    staged in $stage"
