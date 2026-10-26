# Shared bash helpers. Source this file. Works on bash 3.2.

# Root of the code: this file always lives at <root>/libexec/claude-apart/lib/common.sh.
# abs_path resolves any symlinks, so callers may be reached through launcher links.
_ca_here=$(perl -MCwd=abs_path -e 'print abs_path(shift)' "${BASH_SOURCE[0]}")
CA_ROOT=$(cd "$(dirname "$_ca_here")/../../.." && pwd)
CA_HOME=${CLAUDE_APART_HOME:-$HOME/.local/share/claude-apart}

capart() { perl -I"$CA_ROOT/lib" "$CA_ROOT/libexec/claude-apart/capart.pl" "$@"; }

die() { echo "claude-apart: $*" >&2; exit 1; }

ask() { # <prompt> <default>
  local reply
  printf '%s [%s] ' "$1" "$2" >&2
  IFS= read -r reply || reply=
  printf '%s\n' "${reply:-$2}"
}

ask_yn() { # <prompt>; default no
  local reply
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r reply || reply=
  case "$reply" in y|Y|yes|YES|Yes) return 0;; *) return 1;; esac
}

# Path of the wrapper that every launcher link points to.
ca_wrapper() { echo "$CA_ROOT/libexec/claude-apart/wrapper.sh"; }

# The real claude: $CLAUDE_APART_REAL_CLAUDE, else the first `claude` on PATH
# that is not our wrapper (even through symlinks).
find_real_claude() {
  if [ -n "${CLAUDE_APART_REAL_CLAUDE:-}" ]; then
    echo "$CLAUDE_APART_REAL_CLAUDE"
    return 0
  fi
  local w c dir oldifs=$IFS
  w=$(ca_wrapper)
  IFS=:
  for dir in $PATH; do
    IFS=$oldifs
    [ -n "$dir" ] || dir=.
    c=$dir/claude
    if [ -f "$c" ] && [ -x "$c" ] && [ "$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$c")" != "$w" ]; then
      echo "$c"
      return 0
    fi
    IFS=:
  done
  IFS=$oldifs
  echo "claude-apart: cannot find the real claude on PATH." >&2
  return 1
}

# Make $CA_HOME/bin/claude and claude-<name> per profile (symlinks to the
# wrapper). Removes stale claude-* links that point to the wrapper; nothing else.
install_links() {
  local bin=$CA_HOME/bin w names n l want
  w=$(ca_wrapper)
  names=$(capart config profiles) || return 1
  mkdir -p "$bin" || return 1
  for l in "$bin"/claude-*; do
    [ -L "$l" ] || continue
    n=${l##*/}
    [ "$n" = claude-apart ] && continue
    [ "$(readlink "$l")" = "$w" ] || continue
    want=0
    for p in $names; do [ "$n" = "claude-$p" ] && want=1; done
    [ "$want" = 1 ] || rm -f "$l"
  done
  for n in claude $(for p in $names; do echo "claude-$p"; done); do
    if [ -e "$bin/$n" ] && [ ! -L "$bin/$n" ]; then
      echo "claude-apart: $bin/$n exists and is not a link; left alone." >&2
      continue
    fi
    ln -sfn "$w" "$bin/$n" || return 1
  done
}
