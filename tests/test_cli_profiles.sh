# Tests for login, setup, add, remove and status.

# Config lines, trimmed, without blanks and comments, sorted (order and spacing do not matter).
_cfg_norm() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^#' | grep -v '^$' | LC_ALL=C sort
}

# work has no recorded identity yet (profile exists, nothing logged in).
_work_unlogged() {
  t_two_profiles
  capart config set-profile work email "" || return 1
  capart config set-profile work org "" || return 1
  rm -f "$HOME/.claude-work/.claude.json"
}

_cfg_value() { # <profile> <var>: CA_<var> from config shell
  local CA_NAME CA_DIR CA_ADOPTED CA_TAG CA_EMOJI CA_COLOUR CA_EMAIL CA_ORG CA_CAN_READ CA_THEME CA_TMPDIR
  eval "$(capart config shell "$1")"
  eval "printf '%s' \"\$CA_$2\""
}

test_login_records_identity() {
  _work_unlogged || return 1
  export FAKE_LOGIN_EMAIL=w2@example.com FAKE_LOGIN_ORG=org-w2
  run bash -c "printf 'y\n' | claude-apart login work"
  assert_rc 0 "login" || return 1
  assert_eq w2@example.com "$(_cfg_value work EMAIL)" "email recorded" || return 1
  assert_eq org-w2 "$(_cfg_value work ORG)" "org recorded" || return 1
  [ -f "$HOME/.claude-work/settings.json" ] || { echo "settings not synced"; return 1; }
  assert_contains "$(cat "$FAKE_LOG")" "CONFIG_DIR=$HOME/.claude-work PROFILE= ARGS=auth login" "login env" || return 1
}

test_login_adopted_profile_unsets_config_dir() {
  t_two_profiles
  capart config set-profile personal email "" && capart config set-profile personal org "" || return 1
  export FAKE_LOGIN_EMAIL=p2@example.com FAKE_LOGIN_ORG=org-p2
  CLAUDE_CONFIG_DIR=/nonexistent run bash -c "printf 'y\n' | claude-apart login personal"
  assert_rc 0 "login" || return 1
  assert_contains "$(cat "$FAKE_LOG")" "CONFIG_DIR=<unset> PROFILE= ARGS=auth login" "adopted: unset" || return 1
  assert_eq p2@example.com "$(_cfg_value personal EMAIL)" "recorded" || return 1
}

test_login_same_account_as_other_profile_refused() {
  _work_unlogged || return 1
  local before; before=$(cat "$XDG_CONFIG_HOME/claude-apart/config")
  export FAKE_LOGIN_EMAIL=p@example.com FAKE_LOGIN_ORG=org-p
  run bash -c "printf 'y\n' | claude-apart login work"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$(cat "$FAKE_LOG")" "auth logout" "logged out" || return 1
  assert_eq "$before" "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "config unchanged" || return 1
  assert_contains "$ERR" "already used by profile personal" "names the profile" || return 1
  assert_not_contains "$OUT$ERR" "p@example.com" "no other email" || return 1
}

test_login_declined_logs_out() {
  _work_unlogged || return 1
  export FAKE_LOGIN_EMAIL=w2@example.com FAKE_LOGIN_ORG=org-w2
  run bash -c "printf 'n\n' | claude-apart login work"
  assert_rc 1 "declined" || return 1
  assert_contains "$(cat "$FAKE_LOG")" "auth logout" "logged out" || return 1
  assert_eq "" "$(_cfg_value work EMAIL)" "nothing recorded" || return 1
}

test_login_eof_logs_out() {
  _work_unlogged || return 1
  export FAKE_LOGIN_EMAIL=w2@example.com FAKE_LOGIN_ORG=org-w2
  run claude-apart login work < /dev/null
  assert_rc 1 "eof is no" || return 1
  assert_contains "$(cat "$FAKE_LOG")" "auth logout" "logged out" || return 1
}

test_login_empty_org_refused() {
  _work_unlogged || return 1
  export FAKE_LOGIN_EMAIL=w2@example.com FAKE_LOGIN_ORG=
  run bash -c "printf 'y\n' | claude-apart login work"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$(cat "$FAKE_LOG")" "auth logout" "logged out" || return 1
  assert_eq "" "$(_cfg_value work EMAIL)" "nothing recorded" || return 1
}

test_login_never_sends_a_prompt() {
  _work_unlogged || return 1
  export FAKE_LOGIN_EMAIL=w2@example.com FAKE_LOGIN_ORG=org-w2
  run bash -c "printf 'y\n' | claude-apart login work"
  local args; args=$(sed -n 's/.* ARGS=\(.*\) TMPDIR_CC=.*/\1/p' "$FAKE_LOG" | sort -u)
  assert_eq "auth login" "$args" "only auth login" || return 1
}

test_login_refused_in_session() {
  _work_unlogged || return 1
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart login work
  assert_rc 1 "refused" || return 1
  [ ! -e "$FAKE_LOG" ] || { echo "claude was run"; return 1; }
}

test_login_unknown_profile() {
  t_two_profiles
  run claude-apart login nope
  assert_rc 1 "unknown" || return 1
}

test_setup_fresh_two_profiles() {
  t_two_profiles
  local expected; expected=$(_cfg_norm "$XDG_CONFIG_HOME/claude-apart/config")
  rm -f "$XDG_CONFIG_HOME/claude-apart/config"
  rm -rf "$HOME/.claude-work"
  export FAKE_LOGIN_EMAIL=w@example.com FAKE_LOGIN_ORG=org-w
  # adopt? name, emoji, colour, confirm | another: work, emoji, colour, confirm | none | default | grants
  run bash -c "printf 'y\n\n\n\ny\nwork\n\n\ny\n\nwork\ny\nn\n' | claude-apart setup"
  assert_rc 0 "setup" || return 1
  assert_eq "$expected" "$(_cfg_norm "$XDG_CONFIG_HOME/claude-apart/config")" "config equals the fixture" || return 1
  [ -L "$CLAUDE_APART_HOME/bin/claude-work" ] || { echo "no launcher"; return 1; }
  assert_eq "$REPO/libexec/claude-apart/wrapper.sh" "$(readlink "$CLAUDE_APART_HOME/bin/claude-work")" "links to wrapper" || return 1
  assert_contains "$OUT" "✓ work:" "check ran" || return 1
  assert_not_contains "$OUT" "✗" "check passed" || return 1
}

test_setup_fresh_eof_exits_1() {
  t_two_profiles
  rm -f "$XDG_CONFIG_HOME/claude-apart/config"
  run claude-apart setup < /dev/null
  assert_rc 1 "eof" || return 1
}

test_setup_menu_eof_exits_1() {
  t_two_profiles
  run claude-apart setup < /dev/null
  assert_rc 1 "eof at menu" || return 1
}

test_setup_menu_done() {
  t_two_profiles
  run bash -c "printf 'done\n' | claude-apart setup"
  assert_rc 0 "done" || return 1
}

test_setup_menu_bad_choice_then_eof_ends() {
  t_two_profiles
  run bash -c "printf 'nonsense\nmore\n' | claude-apart setup"
  assert_rc 1 "ends at eof" || return 1
}

test_setup_menu_default_and_grants() {
  t_two_profiles
  # default -> personal; grants: personal reads work? n, work reads personal? y
  run bash -c "printf 'default\npersonal\ngrants\nn\ny\ndone\n' | claude-apart setup"
  assert_rc 0 "menu" || return 1
  assert_eq personal "$(capart config default)" "default changed" || return 1
  assert_eq "" "$(_cfg_value personal CAN_READ)" "personal grant gone" || return 1
  assert_eq personal "$(_cfg_value work CAN_READ)" "work grant added" || return 1
  # grants end with a sync: work now needs a deny for nothing of personal's... settings exist
  [ -f "$HOME/.claude/settings.json" ] || { echo "not synced"; return 1; }
}

test_setup_menu_remove_asks_for_default() {
  t_two_profiles
  run bash -c "printf 'remove\nwork\ndone\n' | claude-apart setup"
  # work is the default: refused, the menu goes on
  assert_contains "$(capart config profiles)" "work" "work still there" || return 1
}

test_add_rejects_bad_names() {
  t_two_profiles
  local n
  for n in apart Bad 1x -x "a_b" "$(printf 'a%.0s' $(seq 1 32))"; do
    run claude-apart add "$n" < /dev/null
    [ "$RC" != 0 ] || { echo "accepted: $n"; return 1; }
  done
  assert_eq "personal
work" "$(capart config profiles)" "config unchanged" || return 1
}

test_add_tag_default_and_login() {
  t_two_profiles
  export FAKE_LOGIN_EMAIL=x@example.com FAKE_LOGIN_ORG=org-x
  # emoji, colour, confirm
  run bash -c "printf '\n\ny\n' | claude-apart add research"
  assert_rc 0 "add" || return 1
  assert_eq RESE "$(_cfg_value research TAG)" "tag" || return 1
  assert_eq "$HOME/.claude-research" "$(_cfg_value research DIR)" "dir" || return 1
  assert_eq x@example.com "$(_cfg_value research EMAIL)" "email" || return 1
  [ -L "$CLAUDE_APART_HOME/bin/claude-research" ] || { echo "no launcher"; return 1; }
  [ -f "$HOME/.claude-research/settings.json" ] || { echo "not synced"; return 1; }
}

test_add_with_flags_and_failed_login_rolls_back() {
  t_two_profiles
  export FAKE_LOGIN_EMAIL=p@example.com FAKE_LOGIN_ORG=org-p
  run claude-apart add lab --dir "$HOME/lab-dir" --tag LABX --emoji 🟦 --colour blue < /dev/null
  [ "$RC" != 0 ] || { echo "expected failure (same account)"; return 1; }
  assert_eq "personal
work" "$(capart config profiles)" "profile rolled back" || return 1
  [ ! -e "$CLAUDE_APART_HOME/bin/claude-lab" ] || { echo "launcher left"; return 1; }
}

test_add_with_flags_ok() {
  t_two_profiles
  export FAKE_LOGIN_EMAIL=l@example.com FAKE_LOGIN_ORG=org-l
  run bash -c "printf 'y\n' | claude-apart add lab --dir '$HOME/lab-dir' --tag LABX --emoji 🟦 --colour blue"
  assert_rc 0 "add" || return 1
  assert_eq LABX "$(_cfg_value lab TAG)" "tag" || return 1
  assert_eq "$HOME/lab-dir" "$(_cfg_value lab DIR)" "dir" || return 1
  assert_contains "$(cat "$FAKE_LOG")" "CONFIG_DIR=$HOME/lab-dir " "login env" || return 1
}

test_add_rejects_dir_used_by_other_profile() {
  t_two_profiles
  run claude-apart add dup --dir "$HOME/.claude-work" < /dev/null
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_eq "personal
work" "$(capart config profiles)" "unchanged" || return 1
}

test_add_adopt() {
  t_two_profiles
  rm -f "$XDG_CONFIG_HOME/claude-apart/config"
  # emoji, colour, confirm identity
  run bash -c "printf '\n\ny\n' | claude-apart add personal --adopt"
  assert_rc 0 "adopt" || return 1
  assert_eq '~/.claude' "$(sed -n 's/^dir = //p' "$XDG_CONFIG_HOME/claude-apart/config")" "dir" || return 1
  assert_eq p@example.com "$(_cfg_value personal EMAIL)" "identity recorded" || return 1
  assert_eq org-p "$(_cfg_value personal ORG)" "org recorded" || return 1
  [ ! -e "$FAKE_LOG" ] || { echo "login was run"; return 1; }
}

test_add_adopt_without_login_refused() {
  t_two_profiles
  rm -f "$XDG_CONFIG_HOME/claude-apart/config" "$HOME/.claude.json"
  run claude-apart add personal --adopt < /dev/null
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  [ ! -e "$XDG_CONFIG_HOME/claude-apart/config" ] || { echo "config written"; return 1; }
}

test_add_refused_in_session() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart add x
  assert_rc 1 "refused" || return 1
}

test_status_lines() {
  t_two_profiles
  run claude-apart sync
  run claude-apart status
  assert_rc 0 "status" || return 1
  assert_contains "$OUT" "🟧 WORK work  ~/.claude-work  w@example.com  w@example.com  -  guard:yes" "work line" || return 1
  assert_contains "$OUT" "🟪 PERS personal  ~/.claude  p@example.com  p@example.com  work  guard:yes" "personal line" || return 1
  rm "$HOME/.claude-work/.claude.json"
  run claude-apart status
  assert_contains "$OUT" "not logged in" "not logged in" || return 1
}

test_status_guard_no_before_sync() {
  t_two_profiles
  run claude-apart status
  assert_contains "$OUT" "guard:no" "no guard" || return 1
}

test_status_hides_others_in_session() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_APART_PROFILE=work CLAUDE_CONFIG_DIR="$HOME/.claude-work" run claude-apart status
  assert_rc 0 "status" || return 1
  assert_not_contains "$OUT" "p@example.com" "other email hidden" || return 1
  assert_not_contains "$OUT" "personal" "other name hidden" || return 1
  assert_contains "$OUT" "work" "own profile shown" || return 1
}

test_status_hides_others_in_session_without_profile_env() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_APART_PROFILE=work run claude-apart status
  # CLAUDE_CONFIG_DIR unset means the adopted profile: the env name disagrees, so nothing is shown
  assert_not_contains "$OUT" "p@example.com" "no leak" || return 1
  assert_not_contains "$OUT" "w@example.com" "nothing" || return 1
}

test_remove_keeps_dir() {
  t_two_profiles
  capart config set default personal
  run claude-apart sync
  run claude-apart remove work
  assert_rc 0 "remove" || return 1
  [ -d "$HOME/.claude-work" ] || { echo "dir deleted"; return 1; }
  assert_eq personal "$(capart config profiles)" "config has no work" || return 1
  [ ! -e "$T/prefix/bin/claude-work" ] || { echo "launcher left"; return 1; }
}

test_remove_cleans_work_settings_and_resyncs_others() {
  t_two_profiles
  capart config set default personal
  run claude-apart sync
  run claude-apart remove work
  assert_rc 0 "remove" || return 1
  assert_not_contains "$(cat "$HOME/.claude/settings.json")" ".claude-work" "personal has no rule for work" || return 1
  assert_not_contains "$(cat "$HOME/.claude-work/settings.json" 2>/dev/null)" "claude-apart" "work settings cleaned" || return 1
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "can_read" "grant pruned" || return 1
}

test_remove_default_refused() {
  t_two_profiles
  run claude-apart sync
  run claude-apart remove work
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$(capart config profiles)" "work" "still there" || return 1
}

test_remove_unknown_profile() {
  t_two_profiles
  run claude-apart remove nope
  [ "$RC" != 0 ] || return 1
}

test_remove_delete_dir_asks_and_deletes() {
  t_two_profiles
  capart config set default personal
  run bash -c "printf 'n\n' | claude-apart remove work --delete-dir"
  [ -d "$HOME/.claude-work" ] || { echo "deleted without yes"; return 1; }
  t_two_profiles
  capart config set default personal
  run bash -c "printf 'y\n' | claude-apart remove work --delete-dir"
  assert_rc 0 "remove" || return 1
  [ ! -e "$HOME/.claude-work" ] || { echo "dir still there"; return 1; }
  [ -d "$HOME" ] || return 1
}

test_remove_delete_dir_refuses_adopted() {
  t_two_profiles
  capart config set default work
  run bash -c "printf 'y\n' | claude-apart remove personal --delete-dir"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  [ -d "$HOME/.claude" ] || { echo "adopted dir deleted"; return 1; }
  assert_contains "$(capart config profiles)" "personal" "profile kept (refused up front)" || return 1
}

test_remove_delete_dir_refuses_home_and_outside() {
  t_two_profiles
  capart config set default personal
  local out="$T/outside"; mkdir -p "$out"
  capart config set-profile work dir "$HOME" || return 1
  run bash -c "printf 'y\n' | claude-apart remove work --delete-dir"
  [ "$RC" != 0 ] || { echo "home: expected failure"; return 1; }
  [ -d "$HOME" ] && [ -f "$HOME/.claude.json" ] || { echo "HOME damaged"; return 1; }
  capart config set-profile work dir "$out" || return 1
  run bash -c "printf 'y\n' | claude-apart remove work --delete-dir"
  [ "$RC" != 0 ] || { echo "outside: expected failure"; return 1; }
  [ -d "$out" ] || { echo "outside dir deleted"; return 1; }
}

test_remove_delete_dir_refuses_symlink_and_other_profiles_dir() {
  t_two_profiles
  capart config set default personal
  mkdir -p "$T/real"
  rm -rf "$HOME/.claude-work"; ln -s "$T/real" "$HOME/.claude-work"
  run bash -c "printf 'y\n' | claude-apart remove work --delete-dir"
  [ "$RC" != 0 ] || { echo "symlink: expected failure"; return 1; }
  [ -d "$T/real" ] || { echo "target deleted"; return 1; }
}

test_remove_refused_in_session() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart remove work
  assert_rc 1 "refused" || return 1
}
