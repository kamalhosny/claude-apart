# claude-apart copy <from> <to>: copy chosen items from one profile to another.
# Sourced by bin/claude-apart. Every item is shown and asked about on its own.
# Answers come from the terminal (CLAUDE_APART_TTY or /dev/tty), never from
# stdin, so nothing piped in can approve anything. End of input counts as "no".
ca_copy() {
  [ $# -eq 2 ] || { echo "Usage: claude-apart copy <from> <to>" >&2; return 2; }
  if [ "${CLAUDE_CODE_CHILD_SESSION:-}" = 1 ]; then
    echo "claude-apart: run this in a normal terminal, not inside Claude." >&2
    return 1
  fi
  local from=$1 to=$2 tty=${CLAUDE_APART_TTY:-/dev/tty}
  local items kind id label prev reply res copied=0 skipped=0 eof=0
  if ! ( : <"$tty" ) 2>/dev/null; then
    echo "claude-apart: cannot open the terminal to ask questions; nothing was copied." >&2
    return 1
  fi
  items=$(capart copy-items "$from" "$to" </dev/null) || return 1
  if [ -z "$items" ]; then echo "Nothing to copy from $from."; echo "Copied 0, skipped 0."; return 0; fi
  exec 3<"$tty"
  while IFS=$'\t' read -r kind id label prev; do
    [ -n "$kind" ] || continue
    if [ "$eof" = 1 ]; then skipped=$((skipped + 1)); continue; fi
    printf '\n[%s] %s\n' "$kind" "$label"
    printf '%b\n' "$prev" | sed 's/^/    | /'
    echo "  this will be visible to $to's account"
    printf 'Copy? [y/N] '
    if ! IFS= read -r reply <&3 && [ -z "$reply" ]; then
      eof=1; skipped=$((skipped + 1))
      echo; echo "No more answers; skipping the rest."
      continue
    fi
    case "$reply" in
      y|Y|yes|YES|Yes)
        if res=$(capart copy-apply "$from" "$to" "$kind" "$id" </dev/null 2>&1); then
          copied=$((copied + 1)); echo "  $res"
        else
          skipped=$((skipped + 1)); echo "  not copied: ${res#claude-apart: }"
        fi ;;
      *) skipped=$((skipped + 1)) ;;
    esac
  done <<EOF2
$items
EOF2
  exec 3<&-
  echo
  echo "Copied $copied, skipped $skipped."
}
