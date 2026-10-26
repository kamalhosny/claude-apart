# Shared test helpers. Sourced by tests/run.sh and by test files.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$REPO/libexec/claude-apart/lib/common.sh"
export -n CA_ROOT CA_HOME

t_setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/capart.XXXXXX") || return 1
  T=$(cd "$T" && pwd -P)
  export T
  export HOME="$T/home"
  mkdir -p "$HOME" "$T/bin" "$T/prefix"
  export XDG_CONFIG_HOME="$HOME/.config"
  export CLAUDE_APART_HOME="$T/prefix"
  export CA_HOME="$CLAUDE_APART_HOME"
  export CLAUDE_APART_REAL_CLAUDE="$REPO/tests/fixtures/fake-claude"
  export FAKE_LOG="$T/fake.log"
  export PATH="$T/bin:$REPO/bin:/usr/bin:/bin"
  unset CLAUDE_CONFIG_DIR CLAUDE_APART_PROFILE CLAUDE_CODE_CHILD_SESSION CLAUDECODE
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  local v
  for v in $(env | sed -n 's/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_SOCKET
  ln -s "$REPO/libexec/claude-apart/wrapper.sh" "$T/bin/claude"
  ln -s "$REPO/libexec/claude-apart/wrapper.sh" "$T/bin/claude-personal"
  ln -s "$REPO/libexec/claude-apart/wrapper.sh" "$T/bin/claude-work"
}

t_login_as() { # <identity-file> <email> <org>
  mkdir -p "$(dirname "$1")"
  printf '{"oauthAccount":{"emailAddress":"%s","organizationUuid":"%s","organizationName":"Example"}}\n' "$2" "$3" > "$1"
}

t_two_profiles() {
  mkdir -p "$XDG_CONFIG_HOME/claude-apart" "$HOME/.claude" "$HOME/.claude-work"
  cat > "$XDG_CONFIG_HOME/claude-apart/config" <<'CFG'
default = work
[profile personal]
dir = ~/.claude
tag = PERS
emoji = 🟪
colour = purple
email = p@example.com
org = org-p
can_read = work
[profile work]
dir = ~/.claude-work
tag = WORK
emoji = 🟧
colour = orange
email = w@example.com
org = org-w
CFG
  t_login_as "$HOME/.claude.json" p@example.com org-p
  t_login_as "$HOME/.claude-work/.claude.json" w@example.com org-w
}

run() {
  OUT=$("$@" 2>"$T/stderr")
  RC=$?
  ERR=$(cat "$T/stderr")
}

_assert_fail() { printf '  ASSERT FAILED: %s\n    actual: %s\n' "$1" "$2"; return 1; }

assert_eq() { # <expected> <actual> <msg>
  [ "$1" = "$2" ] || { _assert_fail "$3 (expected: $1)" "$2"; return 1; }
}
assert_contains() { # <haystack> <needle> <msg>
  case "$1" in *"$2"*) return 0;; esac
  _assert_fail "$3 (should contain: $2)" "$1"
}
assert_not_contains() { # <haystack> <needle> <msg>
  case "$1" in *"$2"*) _assert_fail "$3 (should not contain: $2)" "$1"; return 1;; esac
  return 0
}
assert_rc() { # <n> [msg]
  [ "$RC" = "$1" ] || _assert_fail "${2:-exit code} (expected rc $1)" "rc=$RC out=[$OUT] err=[$ERR]"
}

hook() { # <profile> <event> <json>
  run perl -I"$REPO/lib" "$REPO/libexec/claude-apart/capart.pl" hook "$2" --profile "$1" <<<"$3"
}

_json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

pre_tool() { # <profile> <tool> <tool_input_json> [cwd]
  local cwd=${4:-$HOME}
  hook "$1" pre-tool "{\"hook_event_name\":\"PreToolUse\",\"cwd\":$(_json_str "$cwd"),\"tool_name\":$(_json_str "$2"),\"tool_input\":$3}"
}
