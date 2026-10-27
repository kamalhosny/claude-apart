# claude-apart status: one line per profile (inside a session: only its own).
# Sourced by bin/claude-apart.
ca_status() {
  [ $# -eq 0 ] || { echo "Usage: claude-apart status" >&2; return 2; }
  capart status
}
