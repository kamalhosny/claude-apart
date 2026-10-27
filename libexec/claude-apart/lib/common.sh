# Shared bash helpers. Source this file. Works on bash 3.2.

# Root of the code: this file always lives at <root>/libexec/claude-apart/lib/common.sh.
# abs_path resolves any symlinks, so callers may be reached through launcher links.
_ca_here=$(perl -MCwd=abs_path -e 'print abs_path(shift)' "${BASH_SOURCE[0]}")
CA_ROOT=$(cd "$(dirname "$_ca_here")/../../.." && pwd)
CA_HOME=${CLAUDE_APART_HOME:-$HOME/.local/share/claude-apart}

capart() { perl -I"$CA_ROOT/lib" "$CA_ROOT/libexec/claude-apart/capart.pl" "$@"; }

die() { echo "claude-apart: $*" >&2; exit 1; }

# CA_EOF becomes 1 when a prompt hits end of input with nothing read, so a
# guided run can stop instead of looping on answers that never come.
CA_EOF=0

ask_to() { # <var> <prompt> <default>: sets <var> in this shell (no subshell)
  local reply
  printf '%s [%s] ' "$2" "$3" >&2
  if ! IFS= read -r reply && [ -z "$reply" ]; then CA_EOF=1; fi
  printf -v "$1" '%s' "${reply:-$3}"
}

ask() { # <prompt> <default>
  local v
  ask_to v "$1" "$2"
  printf '%s\n' "$v"
}

ask_yn() { # <prompt> [y|n]; default no
  local reply def=n hint='y/N'
  [ "${2:-}" = y ] && { def=y; hint='Y/n'; }
  printf '%s [%s] ' "$1" "$hint" >&2
  if ! IFS= read -r reply && [ -z "$reply" ]; then CA_EOF=1; return 1; fi   # EOF means no, whatever the default
  [ -n "$reply" ] || reply=$def
  case "$reply" in y|Y|yes|YES|Yes) return 0;; *) return 1;; esac
}

# The one list of the shell variables `capart config shell` prints.
CA_VARS="NAME DIR ADOPTED TAG EMOJI COLOUR EMAIL ORG CAN_READ THEME TMPDIR"

# Sets CA_<VAR> for one profile (clears the old values first).
ca_load_profile() { # <name>
  local v s
  for v in $CA_VARS; do unset "CA_$v"; done
  s=$(capart config shell "$1") || return 1
  eval "$s"
}

# One value of a profile from the config: ca_profile_var <profile> <VAR from CA_VARS>.
ca_profile_var() {
  ( ca_load_profile "$1" || exit 1; eval "printf '%s\n' \"\$CA_$2\"" )
}

# rc 1 when a folder path has a "." or ".." part: the checks and the delete
# must see the same folder.
ca_dir_plain() { # <path>
  case "/$1/" in */./*|*/../*) return 1;; esac
  return 0
}

# Checks a profile folder against every other profile (skip <skip name>), the
# home folder and ~/.claude: same folder, inside one, or holding one are all
# refused (symlinks, letter case and inodes are handled by capart path-rel).
# <allow_claude>=1 lets the folder be ~/.claude itself (adopting). Message on stderr.
ca_dir_conflict() { # <abs dir> <skip name> <allow_claude>
  local d=$1 skip=$2 allow=$3 p o rel overlap names owned cfgf
  case "$d" in /?*) ;; *) ca_err "that is not a usable folder path."; return 1;; esac
  rel=$(capart path-rel "$d" "$HOME") || return 1
  case "$rel" in same|contains) ca_err "that folder is, or holds, your home folder."; return 1;; esac
  if [ "$allow" != 1 ]; then
    rel=$(capart path-rel "$d" "$HOME/.claude") || return 1
    [ "$rel" = none ] || { ca_err "that folder overlaps ~/.claude, which belongs to the adopted profile."; return 1; }
  fi
  # everything another profile owns: its folder, protect entries, temp folder,
  # and for the adopted one the ~/.claude.json family
  # R67 (4): a list we cannot read refuses (an empty list would pass everything)
  cfgf=${XDG_CONFIG_HOME:-$HOME/.config}/claude-apart/config
  names=
  if [ -e "$cfgf" ] || [ -L "$cfgf" ]; then
    names=$(capart config profiles) || { ca_err "cannot read the profile list; refusing to be safe."; return 1; }
  fi
  for p in $names; do
    [ "$p" = "$skip" ] && continue
    owned=$(capart config owned "$p") || { ca_err "cannot read what profile $p owns; refusing to be safe."; return 1; }
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      overlap=0
      case "$o" in
        *.\*) # a family: the base file and every name that starts with "base."
          o=${o%.\*}
          case "$(printf %s "$d" | tr A-Z a-z)" in "$(printf %s "$o" | tr A-Z a-z)".*) overlap=1;; esac ;;
      esac
      rel=$(capart path-rel "$d" "$o") || return 1
      [ "$rel" = none ] || overlap=1
      if [ "$overlap" = 1 ]; then
        ca_err "that folder overlaps the folder of profile $p (or a path it protects)."
        return 1
      fi
    done <<EOF2
$owned
EOF2
  done
  return 0
}

ca_err() { echo "claude-apart: $*" >&2; }

# Path of the wrapper that every launcher link points to.
ca_wrapper() { echo "$CA_ROOT/libexec/claude-apart/wrapper.sh"; }

# The real claude: $CLAUDE_APART_REAL_CLAUDE, else the first `claude` on PATH
# that is not our wrapper (even through symlinks), nor the wrapper of
# another claude-apart copy on PATH (two installs would start each other).
find_real_claude() {
  if [ -n "${CLAUDE_APART_REAL_CLAUDE:-}" ]; then
    echo "$CLAUDE_APART_REAL_CLAUDE"
    return 0
  fi
  local w c r dir oldifs=$IFS
  w=$(ca_wrapper)
  IFS=:
  for dir in $PATH; do
    IFS=$oldifs
    [ -n "$dir" ] || dir=.
    c=$dir/claude
    if [ -f "$c" ] && [ -x "$c" ]; then
      r=$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$c")
      case "$r" in
        "$w"|*/libexec/claude-apart/wrapper.sh) ;;
        *) echo "$c"; return 0 ;;
      esac
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

# R48: the temp base for scratch folders (tests, `check`). The adopted profile
# owns /tmp/claude-<uid> (Claude Code's temp root, so $TMPDIR inside a
# session), and a scratch HOME under it would be a foreign path for every
# other profile. $TMPDIR (default /tmp) is used only when it exists and its
# real path is outside that root; else /var/tmp.
ca_temp_base() {
  local d=${TMPDIR:-/tmp} r low root
  r=$(cd "$d" 2>/dev/null && pwd -P) || r=
  low=$(printf '%s/' "$r" | tr '[:upper:]' '[:lower:]')
  root=/tmp/claude-$(id -u)/
  case "$low" in
    /|"$root"*|/private"$root"*) echo /var/tmp ;;
    *) echo "$r" ;;
  esac
}
