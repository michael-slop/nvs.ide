#!/usr/bin/env bash
# Run the nvs.ide runtime checks in a sandbox that never touches your own Neovim config.
# The Linux and macOS twin of tests/run.ps1; the two do the same thing.
#
# Points XDG_CONFIG_HOME/DATA/STATE/CACHE at a sandbox folder, links the sandbox's
# nvs-ide config to this repo's runtime/ (a symlink, so edits are live), installs the
# plugins on first use, then runs:
#   tests/verify.lua     startup checks (runs before the main loop)
#   tests/verify_vsx.lua, verify_theme.lua, verify_health.lua  the same, when present
#   tests/verify_ui.lua  main-loop checks (modes, keys, windows; runs inside the loop)
# Every result line starts with PASS or FAIL. Exit code is the FAIL count (at most 255).
#
#   tests/run.sh [--sandbox DIR] [--only core|ui|both] [--quiet]
#
# --sandbox defaults to ${TMPDIR:-/tmp}/nvs-sb.
set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
runtime="$repo/runtime"
sandbox="${TMPDIR:-/tmp}/nvs-sb"
only=both
quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox) sandbox=$2; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --quiet) quiet=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$only" in core|ui|both) ;; *) echo "--only takes core, ui or both" >&2; exit 2 ;; esac

mkdir -p "$sandbox/config" "$sandbox/data" "$sandbox/state" "$sandbox/cache"
export XDG_CONFIG_HOME="$sandbox/config"
export XDG_DATA_HOME="$sandbox/data"
export XDG_STATE_HOME="$sandbox/state"
export XDG_CACHE_HOME="$sandbox/cache"
export NVIM_APPNAME=nvs-ide
# Tells runtime/lua/plugins/nvs.lua to skip tool and parser downloads (see run.ps1).
export NVS_TEST=1

config="$XDG_CONFIG_HOME/nvs-ide"
if [ -L "$config" ]; then
  :
elif [ -e "$config" ]; then
  echo "$config exists and is not a link to $runtime; move it aside." >&2
  exit 2
else
  ln -s "$runtime" "$config"
fi

# stdpath("data"): Neovim adds -data to the folder name on Windows only.
data="$XDG_DATA_HOME/nvs-ide"
mkdir -p "$data"
if [ ! -d "$data/lazy/LazyVim" ]; then
  [ "$quiet" = 1 ] || echo "Installing plugins into $data (first run)..."
  nvim --headless '+Lazy! sync' +qa >/dev/null 2>&1
fi

# Every run starts from the same saved state: Stage 2, welcome already shown.
printf '%s' '{"stage":2,"welcomed":true}' > "$data/nvs-ide.json"

# The UI checks must run INSIDE the main loop (after VimEnter, via a timer), as in run.ps1.
ui_entry='autocmd VimEnter * ++once lua vim.defer_fn(function() local ok, e = pcall(dofile, [[tests/verify_ui.lua]]) if not ok then io.write([[FAIL ui: harness error: ]] .. tostring(e) .. string.char(10)) io.flush() os.exit(3) end end, 800)'
err_file="$sandbox/run-stderr.log"
out_file="$sandbox/run-stdout.log"
: > "$err_file"
: > "$out_file"

cd "$repo" || exit 2
if [ "$only" != ui ]; then
  nvim --headless -c 'luafile tests/verify.lua' >> "$out_file" 2>> "$err_file"
  echo >> "$out_file"
  for extra in tests/verify_vsx.lua tests/verify_theme.lua tests/verify_health.lua; do
    if [ -f "$extra" ]; then
      nvim --headless -c "luafile $extra" >> "$out_file" 2>> "$err_file"
      echo >> "$out_file"
    fi
  done
fi
if [ "$only" != core ]; then
  nvim --headless --cmd 'let g:nvs_test_ui = 1' -c "$ui_entry" >> "$out_file" 2>> "$err_file"
  echo >> "$out_file"
fi

# Neovim's headless output can carry CRs; results are matched per line without them.
results=$(tr -d '\r' < "$out_file" | grep -E '^(PASS|FAIL) ')
fails=$(printf '%s\n' "$results" | grep -c '^FAIL ')
total=$(printf '%s\n' "$results" | grep -c -E '^(PASS|FAIL) ')
if [ "$quiet" != 1 ]; then
  printf '%s\n' "$results"
  other=$( { tr -d '\r' < "$out_file" | grep -v -E '^(PASS|FAIL) ' ; tr -d '\r' < "$err_file" | grep -v -E '^Stage [0-9]: ' ; } | grep -v '^$' | head -20)
  if [ -n "$other" ]; then
    echo '--- other output ---'
    printf '%s\n' "$other"
  fi
fi
echo "$((total - fails)) passed, $fails failed"
[ "$fails" -gt 255 ] && fails=255
exit "$fails"
