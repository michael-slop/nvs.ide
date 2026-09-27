#!/usr/bin/env bash
# Build the nvs.ide Linux package: dist/nvs.ide-<version>-linux-x86_64.tar.gz.
# The Linux twin of scripts/package.ps1.
#
#   scripts/package.sh <version> [--no-bundle] [--no-build]
#
# 1. cargo build --release in shell/ (skipped with --no-build: shell/target/release/nvs-ide
#    is reused).
# 2. Stage dist/nvs.ide/: nvs-ide, runtime/ (as in git, nothing generated), the nvs
#    launcher, install.sh with nvs-ide.desktop and nvs-ide.png, LICENSE, LICENSE-NEOVIDE,
#    README.md, fonts/ (the house font, BigBlueTerm437 Nerd Font Mono, CC BY-SA 4.0, with
#    its licence), and unless --no-bundle, nvim/ (Neovim v0.12.1, Apache-2.0) and rg/
#    (ripgrep 15.2.0, MIT, the static musl build). Downloads come from the projects' GitHub
#    releases into dist/cache/, are checked against the sha256 pinned below, and the
#    binaries are run to check their versions.
# 3. dist/nvs.ide-<version>-linux-x86_64.tar.gz (nvs.ide-<version>-nobundle-... with
#    --no-bundle), read back to check every entry is under nvs.ide/.
set -euo pipefail

NVIM_VERSION=v0.12.1
NVIM_ASSET=nvim-linux-x86_64
NVIM_SHA256=ab757a1fd9ad307d53d2df4045698906a7ca3993d92260dd8fe49108712d57d0
RG_VERSION=15.2.0
RG_ASSET=ripgrep-$RG_VERSION-x86_64-unknown-linux-musl
RG_SHA256=33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c
NF_VERSION=v3.5.1
NF_SHA256=5c2589a37394459fe2207a6e46ccb5c37a978c51c6a5a2f92985a1356be27846
FONT_FILE=BigBlueTerm437NerdFontMono-Regular.ttf

version=""
bundle=1
build=1
for arg in "$@"; do
  case "$arg" in
    --no-bundle) bundle=0 ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) version=$arg ;;
  esac
done
version=${version#v}
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: scripts/package.sh <version like 1.2.3 or 1.2.3-rc1> [--no-bundle] [--no-build]" >&2
  exit 2
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
shell="$repo/shell"
dist="$repo/dist"
stage="$dist/nvs.ide"
cache="$dist/cache"
mkdir -p "$dist" "$cache"

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }

# fetch <url> <file name in cache> <sha256>: download once, check the hash every time.
fetch() {
  local path="$cache/$2"
  if [ ! -f "$path" ]; then
    step "Downloading $1" >&2
    curl -fsSL --retry 3 -o "$path.part" "$1"
    mv "$path.part" "$path"
  fi
  local actual
  actual=$(sha256sum "$path" | cut -d' ' -f1)
  if [ "$actual" != "$3" ]; then
    rm -f "$path"
    echo "$2: sha256 $actual, expected $3. The download was deleted; run again." >&2
    exit 1
  fi
  printf '%s' "$path"
}

# 1. The window -----------------------------------------------------------------------
exe="$shell/target/release/nvs-ide"
if [ "$build" = 0 ]; then
  [ -x "$exe" ] || { echo "--no-build, but $exe does not exist" >&2; exit 1; }
  step "Using the existing $exe"
else
  step "cargo build --release in $shell"
  (cd "$shell" && cargo build --release)
fi
cargo_version=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$shell/Cargo.toml" | head -1)
if [ "$cargo_version" != "$version" ]; then
  echo "warning: packaging as $version, but shell/Cargo.toml says $cargo_version; nvs-ide --version will print $cargo_version. Bump Cargo.toml before tagging a release." >&2
fi

# 2. Staging ---------------------------------------------------------------------------
step "Staging $stage"
rm -rf "$stage"
mkdir -p "$stage"
cp "$exe" "$stage/nvs-ide"

# runtime/ as it is in git: what lazy.nvim and the Settings screen write into a checkout
# (gitignored) must not ship, nor anything a builder left behind.
cp -R "$repo/runtime" "$stage/runtime"
rm -f "$stage/runtime/lazy-lock.json" "$stage/runtime/lazyvim.json" "$stage/runtime/lua/nvs/settings.lua"
if [ -d "$repo/.git" ]; then
  git -C "$repo" ls-files --others --ignored --exclude-standard --directory runtime | while IFS= read -r f; do
    rm -rf "${stage:?}/$f"
  done
fi
find "$stage/runtime" -depth -type d \( -name node_modules -o -name __pycache__ -o -name .git \) -exec rm -rf {} +

install -m 755 "$repo/installer/linux/nvs" "$stage/nvs"
install -m 755 "$repo/installer/linux/install.sh" "$stage/install.sh"
install -m 644 "$repo/installer/linux/nvs-ide.desktop" "$stage/nvs-ide.desktop"
install -m 644 "$repo/assets/nvs.ide.png" "$stage/nvs-ide.png"
cp "$repo/LICENSE" "$stage/LICENSE"
cp "$shell/LICENSE-NEOVIDE" "$stage/LICENSE-NEOVIDE"
cp "$repo/README.md" "$stage/README.md"

step "Bundling the house font (Nerd Fonts $NF_VERSION, BigBlueTerminal)"
archive=$(fetch "https://github.com/ryanoasis/nerd-fonts/releases/download/$NF_VERSION/BigBlueTerminal.tar.xz" "BigBlueTerminal-$NF_VERSION.tar.xz" "$NF_SHA256")
mkdir -p "$stage/fonts"
tar -xJf "$archive" -C "$stage/fonts" "$FONT_FILE" LICENSE.TXT README.md
mv "$stage/fonts/LICENSE.TXT" "$stage/fonts/LICENSE-BigBlueTerminal.txt"
mv "$stage/fonts/README.md" "$stage/fonts/README-NerdFonts.md"
cat > "$stage/fonts/NOTICE.txt" <<EOF
$FONT_FILE is BigBlue Terminal by VileR (https://int10h.org), (c) 2015, licensed under
the Creative Commons Attribution-ShareAlike 4.0 International License
(LICENSE-BigBlueTerminal.txt), as patched by Nerd Fonts $NF_VERSION
(https://github.com/ryanoasis/nerd-fonts). It is unmodified from Nerd Fonts' release
archive BigBlueTerminal.tar.xz; README-NerdFonts.md, from the same archive, lists the
licences of the icon sets the patch adds. nvs-ide loads it from this folder, so it does
not need to be installed.
EOF

if [ "$bundle" = 1 ]; then
  step "Bundling Neovim $NVIM_VERSION"
  archive=$(fetch "https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/$NVIM_ASSET.tar.gz" "$NVIM_ASSET-$NVIM_VERSION.tar.gz" "$NVIM_SHA256")
  tar -xzf "$archive" -C "$stage"
  mv "$stage/$NVIM_ASSET" "$stage/nvim"
  v=$("$stage/nvim/bin/nvim" --version | head -1)
  [[ $v == "NVIM $NVIM_VERSION" ]] || { echo "bundled nvim says '$v', expected NVIM $NVIM_VERSION" >&2; exit 1; }
  echo "    $v"

  step "Bundling ripgrep $RG_VERSION"
  archive=$(fetch "https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION/$RG_ASSET.tar.gz" "$RG_ASSET.tar.gz" "$RG_SHA256")
  x="$cache/rg-$RG_VERSION"
  rm -rf "$x"
  mkdir -p "$x" "$stage/rg"
  tar -xzf "$archive" -C "$x"
  cp "$x/$RG_ASSET/rg" "$stage/rg/rg"
  for f in COPYING LICENSE-MIT UNLICENSE; do
    [ -f "$x/$RG_ASSET/$f" ] && cp "$x/$RG_ASSET/$f" "$stage/rg/"
  done
  v=$("$stage/rg/rg" --version | head -1)
  [[ $v == "ripgrep $RG_VERSION"* ]] || { echo "bundled rg says '$v', expected ripgrep $RG_VERSION" >&2; exit 1; }
  echo "    $v"
fi

# The staged exe finds what was staged next to it (no display needed for --version).
"$stage/nvs-ide" --version | sed 's/^/    /'

# 3. Tarball ---------------------------------------------------------------------------
variant=""
[ "$bundle" = 1 ] || variant="-nobundle"
out="$dist/nvs.ide-$version$variant-linux-x86_64.tar.gz"
step "Writing $out"
rm -f "$out"
tar --owner=0 --group=0 --numeric-owner -czf "$out" -C "$dist" nvs.ide
entries=$(tar -tzf "$out" | wc -l)
bad=$(tar -tzf "$out" | grep -v -c '^nvs\.ide/' || true)
if [ "$entries" -eq 0 ] || [ "$bad" -ne 0 ]; then
  rm -f "$out"
  echo "$out has $entries entries, $bad outside nvs.ide/; deleted" >&2
  exit 1
fi
echo "    $entries entries, all under nvs.ide/"

step "Done"
awk -v name="$(basename "$out")" -v size="$(stat -c %s "$out")" 'BEGIN { printf "    %-60s %6.1f MB\n", name, size / 1048576 }'
echo "    staged in $stage"
