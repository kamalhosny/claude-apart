# Shared bash helpers. Source this file. Works on bash 3.2.

if [ -z "${CA_ROOT:-}" ]; then
  _ca_self=$0
  while [ -L "$_ca_self" ]; do
    _ca_dir=$(cd "$(dirname "$_ca_self")" && pwd)
    _ca_self=$(readlink "$_ca_self")
    case "$_ca_self" in /*) ;; *) _ca_self="$_ca_dir/$_ca_self";; esac
  done
  CA_ROOT=$(cd "$(dirname "$_ca_self")/.." && pwd)
  case "$CA_ROOT" in */libexec/claude-apart) CA_ROOT=$(cd "$CA_ROOT/../.." && pwd);; esac
fi
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
