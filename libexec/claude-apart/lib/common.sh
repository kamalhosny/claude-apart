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
