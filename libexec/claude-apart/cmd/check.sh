# claude-apart check: self-test of the guard and identity rules (changes nothing).
# Sourced by bin/claude-apart. The scratch folder for check (g) goes under the
# temp base from common.sh, outside Claude's own temp root.
ca_check() {
  [ $# -eq 0 ] || { echo "Usage: claude-apart check" >&2; return 2; }
  capart check --tmp-base "$(ca_temp_base)"
}
