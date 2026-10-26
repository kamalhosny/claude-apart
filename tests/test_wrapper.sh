# Tests for the claude wrapper, profile resolution and identity check.

_log() { cat "$FAKE_LOG" 2>/dev/null; }

_herdr_stub() { # <label>
  cat > "$T/bin/herdr" <<STUB
#!/bin/bash
echo '{"id":"cli:workspace:get","result":{"type":"workspace_info","workspace":{"label":"$1","workspace_id":"w9"}}}'
STUB
  chmod +x "$T/bin/herdr"
}

test_plain_claude_uses_default() {
  t_two_profiles
  run claude --foo
  assert_rc 0 "claude" || return 1
  assert_eq "CONFIG_DIR=$HOME/.claude-work PROFILE=work ARGS=--foo" "$(_log)" "default profile" || return 1
}

test_launcher_personal_unsets_config_dir() {
  t_two_profiles
  run claude-personal
  assert_rc 0 "claude-personal" || return 1
  assert_eq "CONFIG_DIR=<unset> PROFILE=personal ARGS=" "$(_log)" "personal adopted" || return 1
}

test_env_profile_wins_over_default() {
  t_two_profiles
  CLAUDE_APART_PROFILE=personal run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "CONFIG_DIR=<unset> PROFILE=personal" "env profile" || return 1
}

test_inside_session_plain_claude_keeps_own_profile() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "PROFILE=personal" "adopted profile inside session" || return 1
  assert_not_contains "$(_log)" "PROFILE=work" "not the default" || return 1
}

test_inside_session_config_dir_selects_profile() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CONFIG_DIR="$HOME/.claude-work" run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "PROFILE=work" "config dir match" || return 1
}

test_inside_work_session_cannot_start_personal() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_APART_PROFILE=work run claude-personal
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_eq "" "$(_log)" "nothing logged" || return 1
}

test_inside_session_unknown_config_dir_refuses() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CONFIG_DIR="$HOME/elsewhere" run claude
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_eq "" "$(_log)" "nothing logged" || return 1
}

test_unknown_launcher_refuses() {
  t_two_profiles
  ln -s "$REPO/libexec/claude-apart/wrapper.sh" "$T/bin/claude-nope"
  run claude-nope
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_eq "" "$(_log)" "nothing logged" || return 1
}

test_wrong_identity_refuses() {
  t_two_profiles
  t_login_as "$HOME/.claude-work/.claude.json" p@example.com org-p
  run claude
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_contains "$ERR" "claude-apart login work" "identity text" || return 1
  assert_not_contains "$ERR" "p@example.com" "no email in message" || return 1
  assert_eq "" "$(_log)" "nothing logged" || return 1
}

test_not_logged_in_refuses() {
  t_two_profiles
  rm "$HOME/.claude-work/.claude.json"
  run claude
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_contains "$ERR" "not logged in to the account recorded for this profile. Run: claude-apart login work" "fixed text" || return 1
  assert_eq "" "$(_log)" "nothing logged" || return 1
}

test_version_skips_identity() {
  t_two_profiles
  rm "$HOME/.claude-work/.claude.json"
  run claude --version
  assert_rc 0 "--version" || return 1
  assert_contains "$(_log)" "ARGS=--version" "logged" || return 1
}

test_api_key_refused() {
  t_two_profiles
  ANTHROPIC_API_KEY=x run claude
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_eq "" "$(_log)" "nothing logged" || return 1
  ANTHROPIC_API_KEY=x run claude --allow-api-key hi
  assert_rc 0 "allowed" || return 1
  assert_contains "$(_log)" "ARGS=hi" "args kept" || return 1
  assert_not_contains "$(_log)" "allow-api-key" "flag stripped" || return 1
}

test_herdr_label_selects_profile() {
  t_two_profiles
  _herdr_stub "🟪 PERS · ideas"
  HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "PROFILE=personal" "label picks personal" || return 1
}

test_herdr_unlabelled_falls_back_to_default() {
  t_two_profiles
  _herdr_stub "xpark"
  HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "PROFILE=work" "default" || return 1
}

test_herdr_label_prefix_only_matches_whole_tag() {
  t_two_profiles
  _herdr_stub "🟪 PERSONAL stuff"
  HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "PROFILE=work" "no partial tag match" || return 1
}

test_herdr_missing_falls_back_to_default() {
  t_two_profiles
  HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "PROFILE=work" "default" || return 1
}

test_herdr_hang_falls_back_to_default() {
  t_two_profiles
  printf '#!/bin/bash\nsleep 30\n' > "$T/bin/herdr"; chmod +x "$T/bin/herdr"
  HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 run claude
  assert_rc 0 "claude" || return 1
  assert_contains "$(_log)" "PROFILE=work" "default after timeout" || return 1
}

test_no_config_passthrough() {
  run claude x
  assert_rc 0 "claude" || return 1
  assert_eq "CONFIG_DIR=<unset> PROFILE= ARGS=x" "$(_log)" "untouched" || return 1
}

test_identity_check_codes() {
  t_two_profiles
  run capart identity-check work
  assert_rc 0 "ok" || return 1
  t_login_as "$HOME/.claude-work/.claude.json" p@example.com org-p
  run capart identity-check work
  assert_rc 4 "mismatch" || return 1
  assert_eq "p@example.com" "$OUT" "actual email" || return 1
  printf '{}\n' > "$HOME/.claude-work/.claude.json"
  run capart identity-check work
  assert_rc 3 "no oauthAccount" || return 1
  rm "$HOME/.claude-work/.claude.json"
  run capart identity-check work
  assert_rc 3 "no file" || return 1
}

test_install_links() {
  t_two_profiles
  local w="$REPO/libexec/claude-apart/wrapper.sh" b="$CA_HOME/bin"
  mkdir -p "$b"
  ln -s "$w" "$b/claude-old"
  echo keep > "$b/claude-apart"
  ln -s /usr/bin/true "$b/claude-x"
  install_links
  local n
  for n in claude claude-personal claude-work; do
    [ -L "$b/$n" ] && [ "$(readlink "$b/$n")" = "$w" ] || { echo "bad link $n"; return 1; }
  done
  [ ! -e "$b/claude-old" ] && [ ! -L "$b/claude-old" ] || { echo "stale link kept"; return 1; }
  [ -f "$b/claude-apart" ] && [ ! -L "$b/claude-apart" ] || { echo "claude-apart touched"; return 1; }
  assert_eq "/usr/bin/true" "$(readlink "$b/claude-x")" "foreign link untouched" || return 1
}
