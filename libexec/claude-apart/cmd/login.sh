# claude-apart login <name>: the only first-login path. Runs the real
# `claude auth login` / `auth logout` for the profile and nothing else, so no
# prompt can be sent. Sourced by bin/claude-apart.

# Run the real claude's `auth <login|logout>` with the profile's own env, as
# the wrapper does: CLAUDE_CONFIG_DIR set for a normal profile, unset for the
# adopted one, and the profile's own temp folder (mode 700).
_ca_auth() { # <name> <login|logout>
  (
    ca_load_profile "$1" || exit 1
    real=$(find_real_claude) || exit 1
    (umask 077; mkdir -p "$CA_DIR" "$CA_TMPDIR") && chmod 700 "$CA_TMPDIR" || exit 1
    export CLAUDE_CODE_TMPDIR=$CA_TMPDIR
    unset CLAUDE_APART_PROFILE ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
    if [ "$CA_ADOPTED" = 1 ]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR=$CA_DIR; fi
    exec "$real" auth "$2"
  )
}

_ca_logout() { # <name>
  _ca_auth "$1" logout >/dev/null 2>&1 || ca_err "could not log out; log out by hand (run claude auth logout for that profile)."
}

# Login without the final sync (add calls it, then syncs once itself).
_ca_login_core() { # <name>
  local name=$1 id email org oname
  capart config shell "$name" >/dev/null || return 1
  # A failed login may still have written a login; always log out on a failure.
  _ca_auth "$name" login || { ca_err "login failed."; _ca_logout "$name"; return 1; }
  id=$(capart identity-read "$name") || { ca_err "the login shows no account; nothing recorded."; _ca_logout "$name"; return 1; }
  { IFS= read -r email; IFS= read -r org; IFS= read -r oname; } <<EOF2
$id
EOF2
  _ca_confirm_identity "$name" "$email" "$org" "$oname" 1
}

# The shared tail of login and adopt: refuse an empty identity or one that
# another profile already holds, ask, then record email and org in ONE write.
# <logout>=0 for an account that was already there (adopting): it stays logged in.
_ca_confirm_identity() { # <name> <email> <org> <org name> <logout 1|0>
  local name=$1 email=$2 org=$3 oname=$4 lo=$5 other
  if [ -z "$email" ] || [ -z "$org" ]; then
    ca_err "the login shows no email or organisation, so it cannot be told apart from other accounts."
    [ "$lo" = 1 ] && _ca_logout "$name"
    return 1
  fi
  if other=$(capart identity-dup "$name" "$email" "$org"); then
    ca_err "this account is already used by profile $other."
    [ "$lo" = 1 ] && _ca_logout "$name"
    return 1
  fi
  echo "Account: $email (organisation: ${oname:-$org})."
  if ! ask_yn "Use this account for $name?"; then
    [ "$lo" = 1 ] && _ca_logout "$name"
    return 1
  fi
  capart config set-fields "$name.email=$email" "$name.org=$org"
}

ca_login() {
  [ $# -eq 1 ] || { echo "Usage: claude-apart login <name>" >&2; return 2; }
  . "$CA_ROOT/libexec/claude-apart/cmd/sync.sh"
  _ca_login_core "$1" || return 1
  ca_sync
}
