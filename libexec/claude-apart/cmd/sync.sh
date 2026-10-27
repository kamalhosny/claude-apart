# claude-apart sync: make the launchers and install the guard into every
# profile's settings. Sourced by bin/claude-apart (so CA_ROOT and capart come
# from common.sh). One line per profile; a failure does not stop the others,
# but the exit status is 1 if anything failed.
ca_sync() {
  local names n err failed=0
  names=$(capart config profiles) || die "cannot read the config"
  [ -n "$names" ] || die "no profiles configured"
  # F13: the launchers too, so a reinstall after uninstall (config kept) has them
  install_links || { ca_err "could not make the launchers in $CA_HOME/bin."; failed=1; }
  _ca_sync_err=$(mktemp "${TMPDIR:-/tmp}/capart-sync.XXXXXX") || die "cannot make a temp file"
  trap 'rm -f "$_ca_sync_err"' EXIT
  for n in $names; do
    if capart settings install --profile "$n" >/dev/null 2>"$_ca_sync_err"; then
      echo "$n: installed"
    else
      err=$(tr '\n' ' ' <"$_ca_sync_err")
      err=${err% }
      echo "$n: failed — ${err#claude-apart: }"
      failed=1
    fi
  done
  rm -f "$_ca_sync_err"
  trap - EXIT
  return "$failed"
}

# F20: open sessions keep the hooks they started with.
ca_restart_note() { echo "Restart every open Claude session (and Herdr agents) so they load the guard."; }
