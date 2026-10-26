#!/bin/bash
# The `claude` command: picks the profile, checks the login, starts the real claude.
. "$(dirname "$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$0")")/lib/common.sh"

cfgfile=${XDG_CONFIG_HOME:-$HOME/.config}/claude-apart/config
if [ ! -f "$cfgfile" ]; then
  real=$(find_real_claude) || exit 1
  exec "$real" "$@"
fi

args=()
allow_key=0
for a in "$@"; do
  if [ "$a" = --allow-api-key ]; then allow_key=1; else args[${#args[@]}]=$a; fi
done

if [ "$allow_key" = 0 ] && { [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; }; then
  echo "claude-apart: an API key is set; it would bypass the profile login. Unset it, or pass --allow-api-key." >&2
  exit 1
fi

self=$(basename "$0")
case "$self" in
  claude)   profile=$(capart resolve) || exit 1 ;;
  claude-*) profile=$(capart resolve --explicit "${self#claude-}") || exit 1 ;;
  *)        echo "claude-apart: unknown launcher name." >&2; exit 1 ;;
esac

eval "$(capart config shell "$profile")" || exit 1

case "${args[0]:-}" in
  -v|--version|-h|--help) ;;
  *)
    capart identity-check "$profile" >/dev/null
    case $? in
      0) ;;
      3|4) echo "claude-apart: this session is not logged in to the account recorded for this profile. Run: claude-apart login $profile" >&2; exit 1 ;;
      *) echo "claude-apart: identity check failed." >&2; exit 1 ;;
    esac ;;
esac

real=$(find_real_claude) || exit 1
export CLAUDE_APART_PROFILE=$profile
if [ "$CA_ADOPTED" = 1 ]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR=$CA_DIR; fi
exec "$real" "${args[@]}"
