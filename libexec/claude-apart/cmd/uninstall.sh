# claude-apart uninstall [--purge]
# Sourced by bin/claude-apart. Takes out what claude-apart added: the guard
# in every profile's settings, the PATH line, the launchers and the installed
# copy. Profile folders and logins are never deleted. --purge also deletes
# the config folder and the per-profile temp folders (each after a question).

# Removes the marked PATH lines from one rc file, editing the real file in
# place so a symlinked rc file (dotfiles repo) stays a link and keeps its mode.
_ca_rc_unmark() { # <file>
  [ -f "$1" ] || return 0
  perl -e '
    my $f = shift;
    open my $in, "<", $f or exit 1;
    local $/; my $t = <$in>; close $in;
    (my $n = $t) =~ s/^export PATH="[^"\n]*\/bin:\$PATH"  # claude-apart\n?//mg;
    exit 0 if $n eq $t;
    open my $out, "+<", $f or exit 1;
    print {$out} $n or exit 1;
    truncate($out, length $n) or exit 1;
    close $out or exit 1;
  ' "$1" || { ca_err "cannot edit $1; remove the line ending in '# claude-apart' yourself."; return 1; }
  echo "Removed the PATH line from $1"
}

ca_uninstall() {
  local purge=0 rc=0 names n rcf cfgdir state l t
  local rmfail
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1 ;;
      *) echo "Usage: claude-apart uninstall [--purge]" >&2; return 2 ;;
    esac
    shift
  done

  # R74: never take apart a clone used as the install folder (whichever copy
  # runs this). An installed copy never has install.sh; a clone always does.
  if [ -f "$CA_HOME/install.sh" ]; then
    ca_err "the install folder $CA_HOME has install.sh, so it is a clone, not an installed copy; nothing was removed."
    return 1
  fi

  # 1. the guard out of every profile (only what claude-apart added)
  # a config that exists but cannot be read must stop us: the profiles would
  # keep hooks that point at the copy we are about to remove
  if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/claude-apart/config" ]; then
    names=$(capart config profiles) || { ca_err "cannot read the config; nothing was removed."; return 1; }
  else
    names=
  fi
  for n in $names; do
    if capart settings uninstall --profile "$n" >/dev/null; then
      echo "$n: guard removed"
    else
      ca_err "could not remove the guard from profile $n."
      rc=1
    fi
  done
  # Hooks left behind would point at a copy that is gone, and they fail
  # closed (every tool call blocked). So keep the copy in that case.
  if [ "$rc" != 0 ]; then
    ca_err "nothing else was removed. Fix the problem above and run uninstall again."
    return 1
  fi

  # 2. the PATH lines
  for rcf in "$HOME/.zshrc" "$HOME/.bashrc"; do
    _ca_rc_unmark "$rcf" || rc=1
  done

  # 3. launchers and the installed copy: only what claude-apart put there
  case "$CA_HOME" in
    /?*) ;;
    *) ca_err "unusable install folder: $CA_HOME"; return 1 ;;
  esac
  if [ -d "$CA_HOME/bin" ]; then
    for l in "$CA_HOME"/bin/claude "$CA_HOME"/bin/claude-*; do
      [ -L "$l" ] || continue
      t=$(readlink "$l")
      case "$t" in */libexec/claude-apart/wrapper.sh) rm -f "$l" ;; esac
    done
    rm -f "$CA_HOME/bin/claude-apart"
    rmdir "$CA_HOME/bin" 2>/dev/null
  fi
  # R67 (5): a delete that fails is an error, not a silent leftover
  rmfail=0
  for t in "$CA_HOME/libexec" "$CA_HOME/lib"; do
    rm -rf "$t" || { ca_err "could not delete $t."; rmfail=1; rc=1; }
  done
  rmdir "$CA_HOME" 2>/dev/null
  if [ ! -e "$CA_HOME" ]; then
    echo "Removed $CA_HOME"
  elif [ "$rmfail" = 0 ]; then
    echo "Kept $CA_HOME: it holds files claude-apart did not make."
  fi

  # 4. optional: config and temp folders
  if [ "$purge" = 1 ]; then
    cfgdir=${XDG_CONFIG_HOME:-$HOME/.config}/claude-apart
    case "${XDG_STATE_HOME:-}" in /*) state=$XDG_STATE_HOME ;; *) state=$HOME/.local/state ;; esac
    state=$state/claude-apart
    if [ -d "$cfgdir" ] && ask_yn "Delete the claude-apart config folder $cfgdir?"; then
      if rm -rf "$cfgdir"; then echo "Deleted $cfgdir"; else ca_err "could not delete $cfgdir."; rc=1; fi
    fi
    if [ -d "$state" ] && ask_yn "Delete the per-profile temp folders in $state?"; then
      if rm -rf "$state"; then echo "Deleted $state"; else ca_err "could not delete $state."; rc=1; fi
    fi
  fi

  echo "Profile folders and logins were not touched."
  echo "Restart every open Claude session; open sessions still point at the removed copy."
  return "$rc"
}
