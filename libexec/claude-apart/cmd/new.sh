# claude-apart new <name> [label] [--cwd DIR]: open a Herdr workspace for a profile.
# Sourced by bin/claude-apart. Prints the new workspace id.
ca_new() {
  [ $# -ge 1 ] || { echo "Usage: claude-apart new <name> [label] [--cwd DIR]" >&2; return 2; }
  capart new "$@"
}
