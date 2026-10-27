# claude-apart remove <name> [--delete-dir]
# Sourced by bin/claude-apart (and by setup). The profile's folder stays unless
# --delete-dir is given and confirmed; even then only a folder that is safe.

# rc 0 only when a profile's own folder may be deleted. Sets CA_REAL to the
# exact path that was checked (symlinks resolved); that path is what gets
# deleted. Never ~/.claude (any spelling or letter case), $HOME or anything
# not strictly under it, never a link, never a folder that holds or sits
# inside another profile's folder, and only a folder that looks like a Claude
# config folder. A missing folder is fine (CA_REAL is empty).
_ca_dir_deletable() { # <name> <dir>
  local name=$1 d=$2 rel
  CA_REAL=
  ca_dir_plain "$d" || { ca_err "$d has a . or .. part; not deleting it."; return 1; }
  [ ! -L "$d" ] || { ca_err "$d is a link; not deleting it."; return 1; }
  [ -e "$d" ] || return 0
  CA_REAL=$(capart canon "$d") || { CA_REAL=; return 1; }
  rel=$(capart path-rel "$CA_REAL" "$HOME") || return 1
  [ "$rel" = inside ] || { ca_err "$d is not inside your home folder; not deleting it."; CA_REAL=; return 1; }
  rel=$(capart path-rel "$CA_REAL" "$HOME/.claude") || return 1
  [ "$rel" = none ] || { ca_err "~/.claude is never deleted."; CA_REAL=; return 1; }
  if [ ! -e "$CA_REAL/.claude.json" ] && [ ! -e "$CA_REAL/settings.json" ] && [ ! -e "$CA_REAL/.claude-apart-state.json" ]; then
    ca_err "$d does not look like a Claude config folder; not deleting it."
    CA_REAL=; return 1
  fi
  # shared with add: other profiles' folders, protect entries, temp folders
  ca_dir_conflict "$CA_REAL" "$name" 0 || { ca_err "not deleting $d."; CA_REAL=; return 1; }
  return 0
}

ca_remove() {
  local name delete=0 dir adopted others p rc=0 prc
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
  others=0
  for p in $(capart config profiles); do [ "$p" = "$name" ] || others=1; done
  # the last profile may go even if it is the default
  if [ "$others" = 1 ] && [ "$(capart config default)" = "$name" ]; then
    ca_err "$name is the default profile. Choose another default first (claude-apart setup, then: default)."
    return 1
  fi
  dir=$(ca_profile_var "$name" DIR)
  adopted=$(ca_profile_var "$name" ADOPTED)
  # R64: the adopted folder is what a launcher miss lands in; the others stay
  # in place until it is the last one.
  if [ "$adopted" = 1 ] && [ "$others" = 1 ]; then
    ca_err "$name is the adopted profile (~/.claude). Remove the other profiles first."
    return 1
  fi

  # Everything is checked and asked BEFORE anything changes.
  if [ "$delete" = 1 ]; then
    if [ "$adopted" = 1 ]; then ca_err "the adopted folder ~/.claude is never deleted."; return 1; fi
    _ca_dir_deletable "$name" "$dir" || return 1
    if [ -z "$CA_REAL" ]; then
      echo "There is no folder $dir to delete."
      delete=0
    elif ! ask_yn "Delete the folder $dir and everything in it?"; then
      delete=0
    fi
  fi
  if [ "$delete" = 0 ] && [ "$others" = 1 ] && [ -e "$dir" ]; then
    ca_err "$dir will no longer be protected from the other profiles."
    ask_yn "Remove profile $name anyway?" || { echo "Nothing changed."; return 1; }
  fi

  # Config first, then the profile's settings; a failed cleanup leaves hooks
  # that name an unknown profile, and those fail closed.
  capart profile-remove "$name"
  prc=$?
  if [ "$prc" = 3 ]; then rc=1
  elif [ "$prc" != 0 ]; then return 1
  fi
  install_links || rc=1
  echo "Removed profile $name."

  if [ "$delete" = 1 ] && [ "$prc" = 0 ]; then
    # checked again right before the delete, and the checked path is deleted
    if _ca_dir_deletable "$name" "$dir"; then
      [ -z "$CA_REAL" ] || { rm -rf -- "$CA_REAL" && echo "Deleted $dir."; }
    else
      ca_err "the profile is removed, but the folder $dir was kept (it failed the safety check)."
      rc=1
    fi
  elif [ -e "$dir" ]; then
    echo "The folder $dir was kept."
  fi

  # R61: the others drop their rules for this profile's folders.
  if [ -n "$(capart config profiles)" ]; then
    . "$CA_ROOT/libexec/claude-apart/cmd/sync.sh"
    ca_sync || rc=1
  fi
  return "$rc"
}
