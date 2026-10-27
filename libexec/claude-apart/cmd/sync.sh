# claude-apart sync: install the guard into every profile's settings.
# Sourced by bin/claude-apart (so CA_ROOT and capart come from common.sh).
# One line per profile; a failure does not stop the others, but the exit
# status is 1 if any profile failed.
ca_sync() {
  local names n err failed=0
  names=$(capart config profiles) || die "cannot read the config"
  [ -n "$names" ] || die "no profiles configured"
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
