# Tests for `claude-apart check` and `claude-apart new`.

_synced() { t_two_profiles; run claude-apart sync; assert_rc 0 "sync"; }

# A herdr stub: logs one argument per line; prints a workspace reply.
_new_stub() { # [exit code]
  cat > "$T/bin/herdr" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$T/herdr.args"
if [ "${1:-0}" != 0 ]; then echo '{"error":{"message":"boom"}}' >&2; exit ${1:-0}; fi
echo '{"id":"cli:workspace:create","result":{"type":"workspace_info","workspace":{"label":"x","workspace_id":"wG"}}}'
STUB
  chmod +x "$T/bin/herdr"
}

_tree() { (cd "$T" && find . -type f -o -type l | sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f" 2>/dev/null)"; done); }

test_check_passes_after_sync() {
  _synced || return 1
  run claude-apart check
  assert_rc 0 "check" || return 1
  assert_contains "$OUT" "✓ work:" "work line" || return 1
  assert_contains "$OUT" "✓ personal:" "personal line" || return 1
  assert_not_contains "$OUT" "✗" "no failure" || return 1
}

test_check_fails_when_rule_removed() {
  _synced || return 1
  perl -MJSON::PP -e '
    my $f = shift; local $/; open my $h, "<", $f or die; my $d = decode_json(<$h>); close $h;
    delete $d->{hooks}{PreToolUse};
    open $h, ">", $f or die; print $h encode_json($d); close $h' "$HOME/.claude-work/settings.json"
  run claude-apart check
  assert_rc 1 "check" || return 1
  assert_contains "$OUT" "✗ work:" "names work" || return 1
  assert_contains "$OUT" "✓ personal:" "personal still fine" || return 1
}

test_check_fails_when_deny_rule_removed() {
  _synced || return 1
  perl -MJSON::PP -e '
    my $f = shift; local $/; open my $h, "<", $f or die; my $d = decode_json(<$h>); close $h;
    $d->{permissions}{deny} = [];
    open $h, ">", $f or die; print $h encode_json($d); close $h' "$HOME/.claude-work/settings.json"
  run claude-apart check
  assert_rc 1 "check" || return 1
  assert_contains "$OUT" "✗ work:" "names work" || return 1
}

test_check_fails_before_sync() {
  t_two_profiles
  run claude-apart check
  assert_rc 1 "check" || return 1
  assert_contains "$OUT" "✗ work:" "names work" || return 1
}

test_check_fails_on_wrong_identity() {
  _synced || return 1
  t_login_as "$HOME/.claude-work/.claude.json" other@example.com org-other
  run claude-apart check
  assert_rc 1 "check" || return 1
  assert_contains "$OUT" "✗ work:" "names work" || return 1
  assert_not_contains "$OUT" "other@example.com" "no email" || return 1
}

test_check_has_no_side_effects() {
  _synced || return 1
  local before after
  before=$(_tree)
  run claude-apart check
  assert_rc 0 "check" || return 1
  after=$(_tree)
  assert_eq "$before" "$after" "file tree unchanged" || return 1
}

test_check_same_inside_session_and_herdr() {
  _synced || return 1
  CLAUDE_CODE_CHILD_SESSION=1 HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 CLAUDE_APART_PROFILE=personal run claude-apart check
  assert_rc 0 "check in a session" || return 1
  assert_not_contains "$OUT" "✗" "no failure" || return 1
}

test_check_removes_its_temp_dir() {
  _synced || return 1
  mkdir "$T/tb"
  TMPDIR="$T/tb" run claude-apart check
  assert_rc 0 "check" || return 1
  assert_eq "" "$(ls -A "$T/tb")" "temp base empty after success" || return 1
  t_login_as "$HOME/.claude-work/.claude.json" other@example.com org-other
  TMPDIR="$T/tb" run claude-apart check
  assert_rc 1 "check with a failure" || return 1
  assert_eq "" "$(ls -A "$T/tb")" "temp base empty after failure" || return 1
}

test_check_removes_temp_dir_on_interrupt() {
  _synced || return 1
  mkdir "$T/tb"
  TMPDIR="$T/tb" claude-apart check >/dev/null 2>&1 &
  local pid=$! i=0
  while [ $i -lt 100 ] && [ -z "$(ls -A "$T/tb")" ]; do sleep 0.05; i=$((i + 1)); done
  pkill -TERM -P "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 0.5
  assert_eq "" "$(ls -A "$T/tb")" "temp base empty after TERM" || return 1
}

test_check_unknown_extra_args_refused() {
  _synced || return 1
  run claude-apart check bogus
  assert_rc 2 "usage" || return 1
}

test_new_creates_labelled_workspace() {
  t_two_profiles; _new_stub
  run claude-apart new personal ideas
  assert_rc 0 "new" || return 1
  assert_eq "wG" "$OUT" "prints only the id" || return 1
  local args; args=$(cat "$T/herdr.args")
  assert_contains "$args" "workspace
create" "subcommand" || return 1
  assert_contains "$args" "--label
🟪 PERS · ideas" "label" || return 1
  assert_contains "$args" "--cwd
$HOME" "cwd is PWD" || return 1
  assert_contains "$args" "--focus" "focus" || return 1
}

test_new_label_defaults_to_name_and_cwd_flag() {
  t_two_profiles; _new_stub
  mkdir -p "$HOME/scratch"
  run claude-apart new work --cwd "$HOME/scratch"
  assert_rc 0 "new" || return 1
  local args; args=$(cat "$T/herdr.args")
  assert_contains "$args" "--label
🟧 WORK · work" "label from name" || return 1
  assert_contains "$args" "--cwd
$HOME/scratch" "cwd flag" || return 1
}

test_new_unknown_profile_refused() {
  t_two_profiles; _new_stub
  run claude-apart new nope
  assert_rc 1 "new nope" || return 1
  [ ! -e "$T/herdr.args" ] || { echo "herdr was called"; return 1; }
}

test_new_needs_herdr() {
  t_two_profiles
  run claude-apart new work
  assert_rc 1 "no herdr" || return 1
  assert_contains "$ERR" "herdr" "message names herdr" || return 1
}

test_new_herdr_failure_exits_1() {
  t_two_profiles; _new_stub 3
  run claude-apart new work
  assert_rc 1 "herdr failed" || return 1
  assert_eq "" "$OUT" "no id printed" || return 1
  assert_contains "$ERR" "claude-apart:" "message" || return 1
}

test_new_inside_session_only_own_profile() {
  t_two_profiles; _new_stub
  # the session's own profile is the adopted one (no CLAUDE_CONFIG_DIR)
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart new work
  assert_rc 1 "other profile refused" || return 1
  assert_contains "$ERR" "claude-apart: inside Claude you can only open a workspace for this session's own profile." "message" || return 1
  [ ! -e "$T/herdr.args" ] || { echo "herdr was called"; return 1; }
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart new personal
  assert_rc 0 "own profile allowed" || return 1
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CONFIG_DIR="$HOME/.claude-work" run claude-apart new work
  assert_rc 0 "own profile by config dir" || return 1
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CONFIG_DIR="$HOME/.claude-work" run claude-apart new personal
  assert_rc 1 "other refused by config dir" || return 1
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CONFIG_DIR="$HOME/nowhere" run claude-apart new work
  assert_rc 1 "unknown own profile refused" || return 1
}
