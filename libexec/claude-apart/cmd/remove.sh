# claude-apart remove <name> [--delete-dir]
# Sourced by bin/claude-apart (and by setup). The profile's folder stays unless
# --delete-dir is given and confirmed; even then only a folder that is safe.

# rc 0 only when a profile's own folder may be deleted. Never the adopted
# folder, never $HOME or anything outside it, never a link, never a folder
# that holds or sits inside another profile's folder, and only a folder that
# looks like a Claude config folder.
_ca_dir_deletable() { # <name> <dir> <adopted>
  local name=$1 d=$2 adopted=$3 real home p o
  [ "$adopted" != 1 ] || { ca_err "the adopted folder ~/.claude is never deleted."; return 1; }
  [ -n "$d" ] || return 1
  [ ! -L "$d" ] || { ca_err "$d is a link; not deleting it."; return 1; }
  [ -d "$d" ] || return 0
  real=$(cd "$d" && pwd -P) || return 1
  home=$(cd "$HOME" && pwd -P) || return 1
  case "$real" in "$home"/?*) ;; *) ca_err "$d is not inside your home folder; not deleting it."; return 1;; esac
  [ "$real" != "$home/.claude" ] || { ca_err "the adopted folder ~/.claude is never deleted."; return 1; }
  if [ ! -e "$real/.claude.json" ] && [ ! -e "$real/settings.json" ] && [ ! -e "$real/.claude-apart-state.json" ]; then
    ca_err "$d does not look like a Claude config folder; not deleting it."
    return 1
  fi
  for p in $(capart config profiles); do
    [ "$p" = "$name" ] && continue
    o=$(ca_profile_var "$p" DIR)
    o=$(cd "$o" 2>/dev/null && pwd -P) || continue
    case "$real/" in "$o"/*) ca_err "$d overlaps another profile's folder; not deleting it."; return 1;; esac
    case "$o/" in "$real"/*) ca_err "$d overlaps another profile's folder; not deleting it."; return 1;; esac
  done
  return 0
}

ca_remove() {
  local name delete=0 dir adopted p keep list r
  [ $# -ge 1 ] || { echo "Usage: claude-apart remove <name> [--delete-dir]" >&2; return 2; }
  name=$1; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --delete-dir) delete=1 ;;
      *) ca_err "unknown option: $1"; return 2 ;;
    esac
    shift
  done
  capart config profiles | grep -qx -- "$name" || { ca_err "unknown profile: $name"; return 1; }
  if [ "$(capart config default)" = "$name" ]; then
    ca_err "$name is the default profile. Choose another default first (claude-apart setup, then: default)."
    return 1
  fi
  dir=$(ca_profile_var "$name" DIR)
  adopted=$(ca_profile_var "$name" ADOPTED)
  # Refuse before changing anything.
  if [ "$delete" = 1 ]; then
    _ca_dir_deletable "$name" "$dir" "$adopted" || return 1
  fi

  capart settings uninstall --profile "$name" >/dev/null || { ca_err "could not clean $name's settings; nothing removed."; return 1; }
  # Other profiles must not keep a read grant for a name that no longer exists.
  for p in $(capart config profiles); do
    [ "$p" = "$name" ] && continue
    list=$(ca_profile_var "$p" CAN_READ)
    keep=
    for r in $list; do [ "$r" = "$name" ] || keep="$keep $r"; done
    keep=${keep# }
    [ "$keep" = "$list" ] || capart config set-profile "$p" can_read "$keep" || return 1
  done
  capart config remove-profile "$name" || return 1
  install_links || return 1
  echo "Removed profile $name."

  if [ "$delete" = 1 ] && [ -d "$dir" ]; then
    if ask_yn "Delete the folder $dir and everything in it?"; then
      # checked again right before the delete
      if _ca_dir_deletable "$name" "$dir" "$adopted"; then rm -rf -- "$dir"; echo "Deleted $dir."; fi
    else
      echo "Kept $dir."
    fi
  else
    echo "The folder $dir was kept."
  fi

  # R61: the others drop their rules for this profile's folders.
  if [ -n "$(capart config profiles)" ]; then
    . "$CA_ROOT/libexec/claude-apart/cmd/sync.sh"
    ca_sync
  fi
}
