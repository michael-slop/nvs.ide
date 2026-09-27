#!/bin/sh
# Put nvs.ide on this user's PATH and application menu, from wherever this folder was
# unpacked. No root, nothing outside your home folder.
#
#   ./install.sh              link nvs and nvs-ide into ~/.local/bin, add the menu entry
#   ./install.sh --uninstall  remove exactly those; this folder and your data stay
#
# Your data (plugins, models, settings) is in ~/.local/share/nvs-ide and the config
# link in ~/.config/nvs-ide; neither is touched here.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
share=${XDG_DATA_HOME:-$HOME/.local/share}
bin=${XDG_BIN_HOME:-$HOME/.local/bin}
apps="$share/applications"
icons="$share/icons/hicolor/64x64/apps"
desktop="$apps/nvs-ide.desktop"
icon="$icons/nvs-ide.png"

# Remove a link only when it points into this folder: never someone else's file.
unlink_ours() {
  if [ -L "$1" ] && [ "$(readlink -f "$1")" = "$here/$2" ]; then
    rm -f "$1"
    echo "removed $1"
  fi
}

refresh() {
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$share/icons/hicolor" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--uninstall" ]; then
  unlink_ours "$bin/nvs" nvs
  unlink_ours "$bin/nvs-ide" nvs-ide
  # The menu entry and icon are ours when the entry starts this folder's exe.
  if [ -f "$desktop" ] && grep -qxF "Exec=\"$here/nvs-ide\" %F" "$desktop"; then
    rm -f "$desktop" "$icon"
    echo "removed $desktop and $icon"
  fi
  refresh
  exit 0
fi
if [ $# -gt 0 ]; then
  sed -n '2,10p' "$0"
  exit 2
fi

mkdir -p "$bin" "$apps" "$icons"
for name in nvs nvs-ide; do
  target="$bin/$name"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "$target exists and is not a link; left alone" >&2
    continue
  fi
  ln -sfn "$here/$name" "$target"
  echo "linked $target -> $here/$name"
done
# The folder goes into a sed replacement, where & | and \ mean something.
here_sed=$(printf '%s' "$here" | sed 's/[&|\\]/\\&/g')
sed "s|@EXEC@|$here_sed/nvs-ide|" "$here/nvs-ide.desktop" > "$desktop"
cp "$here/nvs-ide.png" "$icon"
echo "added $desktop"
refresh

case ":$PATH:" in
  *":$bin:"*) ;;
  *) echo "note: $bin is not on your PATH; add it to use nvs from a terminal" ;;
esac
echo "done: nvs . opens a folder, or start nvs.ide from the application menu"
