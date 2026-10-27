#!/bin/bash
# The `claude` command: picks the profile, checks the login, starts the real claude.
# Without perl the path below would be empty and the source would read a file
# relative to the current folder, so stop first.
command -v perl >/dev/null 2>&1 || { echo "claude-apart: perl not found." >&2; exit 1; }
_ca_self=$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$0") && [ -n "$_ca_self" ] \
  || { echo "claude-apart: cannot find where this script lives." >&2; exit 1; }
. "${_ca_self%/*}/lib/common.sh"

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

if [ "$allow_key" = 0 ] && { [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; }; then
  echo "claude-apart: an API key is set; it would bypass the profile login. Unset it, or pass --allow-api-key." >&2
  exit 1
fi
# Another provider or endpoint: the session would not use the profile's login either.
if [ "$allow_key" = 0 ]; then
  for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_BASE_URL AWS_BEARER_TOKEN_BEDROCK; do
    if [ -n "${!v:-}" ]; then
      echo "claude-apart: $v is set; it would bypass the profile login. Unset it, or pass --allow-api-key." >&2
      exit 1
    fi
  done
fi

self=$(basename "$0")
case "$self" in
  claude)   profile=$(capart resolve) || exit 1 ;;
  claude-*) profile=$(capart resolve --explicit "${self#claude-}") || exit 1 ;;
  *)        echo "claude-apart: unknown launcher name." >&2; exit 1 ;;
esac

ca_load_profile "$profile" || exit 1

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

(umask 077 && mkdir -p "$CA_TMPDIR") && chmod 700 "$CA_TMPDIR" || {
  echo "claude-apart: cannot create the temp folder $CA_TMPDIR." >&2
  exit 1
}
real=$(find_real_claude) || exit 1
export CLAUDE_APART_PROFILE=$profile
export CLAUDE_CODE_TMPDIR=$CA_TMPDIR
if [ "$CA_ADOPTED" = 1 ]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR=$CA_DIR; fi
exec "$real" "${args[@]}"
