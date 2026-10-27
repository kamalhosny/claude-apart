# claude-apart login <name>: the only first-login path. Runs the real
# `claude auth login` / `auth logout` for the profile and nothing else, so no
# prompt can be sent. Sourced by bin/claude-apart.

# Run the real claude's `auth <login|logout>` with the profile's own env:
# CLAUDE_CONFIG_DIR set for a normal profile, unset for the adopted one.
_ca_auth() { # <name> <login|logout>
  local CA_NAME CA_DIR CA_ADOPTED CA_TAG CA_EMOJI CA_COLOUR CA_EMAIL CA_ORG CA_CAN_READ CA_THEME CA_TMPDIR s real
  s=$(capart config shell "$1") || return 1
  eval "$s"
  real=$(find_real_claude) || return 1
  (umask 077; mkdir -p "$CA_DIR") || return 1
  if [ "$CA_ADOPTED" = 1 ]; then
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_APART_PROFILE -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      "$real" auth "$2"
  else
    env -u CLAUDE_APART_PROFILE -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      CLAUDE_CONFIG_DIR="$CA_DIR" "$real" auth "$2"
  fi
}

_ca_logout() { # <name>
  _ca_auth "$1" logout >/dev/null 2>&1 || ca_err "could not log out; run: claude-apart login $1 (and answer no), or log out by hand."
}

# Login without the final sync (add calls it, then syncs once itself).
_ca_login_core() { # <name>
  local name=$1 id email org oname other
  capart config shell "$name" >/dev/null || return 1
  _ca_auth "$name" login || { ca_err "login failed."; return 1; }
  id=$(capart identity-read "$name") || { ca_err "the login shows no account; nothing recorded."; _ca_logout "$name"; return 1; }
  { IFS= read -r email; IFS= read -r org; IFS= read -r oname; } <<EOF2
$id
EOF2
  if [ -z "$email" ] || [ -z "$org" ]; then
    ca_err "the login shows no email or organisation, so it cannot be told apart from other accounts; logged out."
    _ca_logout "$name"
    return 1
  fi
  if other=$(capart identity-dup "$name" "$email" "$org"); then
    ca_err "this account is already used by profile $other; logged out."
    _ca_logout "$name"
    return 1
  fi
  echo "Logged in as $email (organisation: ${oname:-$org})."
  if ! ask_yn "Use this account for $name?"; then
    _ca_logout "$name"
    return 1
  fi
  capart config set-profile "$name" email "$email" && capart config set-profile "$name" org "$org"
}

ca_login() {
  [ $# -eq 1 ] || { echo "Usage: claude-apart login <name>" >&2; return 2; }
  . "$CA_ROOT/libexec/claude-apart/cmd/sync.sh"
  _ca_login_core "$1" || return 1
  ca_sync
}
