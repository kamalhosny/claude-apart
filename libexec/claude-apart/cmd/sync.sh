# claude-apart sync: install the guard into every profile's settings.
# Sourced by bin/claude-apart (so CA_ROOT and capart come from common.sh).
# One line per profile; a failure does not stop the others, but the exit
# status is 1 if any profile failed.
ca_sync() {
  local names n err rc=0 failed=0 errf
  names=$(capart config profiles) || die "cannot read the config"
  [ -n "$names" ] || die "no profiles configured"
  errf=$(mktemp "${TMPDIR:-/tmp}/capart-sync.XXXXXX") || die "cannot make a temp file"
  for n in $names; do
    if capart settings install --profile "$n" >/dev/null 2>"$errf"; then
      echo "$n: installed"
    else
      err=$(tr '\n' ' ' <"$errf")
      echo "$n: failed — ${err#claude-apart: }"
      failed=1
    fi
  done
  rm -f "$errf"
  return "$failed"
}
