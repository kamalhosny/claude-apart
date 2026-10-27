# Tests for login, setup, add, remove and status.

# Config lines, trimmed, without blanks and comments, each prefixed with its section
# (order and spacing do not matter, but a value swapped between profiles shows).
_cfg_norm() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^#' | grep -v '^$' \
    | awk '/^\[/ { sec = $0; next } { print sec "|" $0 }' | LC_ALL=C sort
}

# work has no recorded identity yet (profile exists, nothing logged in).
_work_unlogged() {
  t_two_profiles
  capart config set-profile work email "" || return 1
  capart config set-profile work org "" || return 1
  rm -f "$HOME/.claude-work/.claude.json"
}

_cfg_value() { ca_profile_var "$1" "$2"; }

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
  # F20: the last step says to restart open sessions, once
  assert_eq "Restart every open Claude session (and Herdr agents) so they load the guard." "$(printf '%s\n' "$OUT" | tail -n 1)" "restart line last" || return 1
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c 'Restart every open')" "restart line once" || return 1
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
  # work is the default: refused, the menu goes on and ends with done
  assert_rc 0 "menu ends with done" || return 1
  assert_contains "$ERR" "is the default profile" "refusal message" || return 1
  assert_contains "$OUT" "Profile not removed." "menu says so" || return 1
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

test_add_adopt_without_login_runs_login() {
  t_two_profiles
  rm -f "$XDG_CONFIG_HOME/claude-apart/config" "$HOME/.claude.json"
  export FAKE_LOGIN_EMAIL=p@example.com FAKE_LOGIN_ORG=org-p
  run bash -c "printf '\n\ny\n' | claude-apart add personal --adopt"
  assert_rc 0 "adopt with login" || return 1
  assert_contains "$(cat "$FAKE_LOG")" "CONFIG_DIR=<unset> PROFILE= ARGS=auth login" "login for ~/.claude" || return 1
  assert_eq p@example.com "$(_cfg_value personal EMAIL)" "recorded" || return 1
}

test_add_adopt_without_login_refused_when_login_empty() {
  t_two_profiles
  rm -f "$XDG_CONFIG_HOME/claude-apart/config" "$HOME/.claude.json"
  export FAKE_LOGIN_EMAIL=p@example.com FAKE_LOGIN_ORG=
  run bash -c "printf '\n\ny\n' | claude-apart add personal --adopt"
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


test_status_session_with_mismatched_env_shows_nothing() {
  t_two_profiles
  # CLAUDE_CONFIG_DIR unset means the adopted profile; the env name says work: undecidable
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_APART_PROFILE=work run claude-apart status
  assert_rc 6 "cannot tell" || return 1
  assert_eq "" "$OUT" "no output" || return 1
  assert_not_contains "$ERR" "@example.com" "no email" || return 1
}

test_status_session_own_line() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_APART_PROFILE=work CLAUDE_CONFIG_DIR="$HOME/.claude-work" run claude-apart status
  assert_rc 0 "status" || return 1
  assert_contains "$OUT" "🟧 WORK work  ~/.claude-work  w@example.com  w@example.com  -  guard:no" "own line" || return 1
}

# ---- R63: another profile's data does not reach a session ----

_in_work_session() { # <cmd...>
  CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_APART_PROFILE=work CLAUDE_CONFIG_DIR="$HOME/.claude-work" run "$@"
}

test_session_identity_read_only_own() {
  t_two_profiles
  _in_work_session capart identity-read personal
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_not_contains "$OUT$ERR" "p@example.com" "no other email" || return 1
  _in_work_session capart identity-read work
  assert_rc 0 "own" || return 1
  assert_contains "$OUT" "w@example.com" "own identity" || return 1
}

test_session_identity_dup_refused() {
  t_two_profiles
  _in_work_session capart identity-dup work p@example.com org-p
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_eq "" "$OUT" "no answer" || return 1
}

test_session_config_shell_and_profiles_only_own() {
  t_two_profiles
  _in_work_session capart config shell personal
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_not_contains "$OUT$ERR" "p@example.com" "no other email" || return 1
  _in_work_session capart config shell work
  assert_rc 0 "own shell" || return 1
  _in_work_session capart config profiles
  assert_eq work "$OUT" "only own profile listed" || return 1
}

test_outside_session_identity_dup_works() {
  t_two_profiles
  run capart identity-dup work p@example.com org-p
  assert_rc 0 "found" || return 1
  assert_eq personal "$OUT" "names the profile" || return 1
}

# ---- remove ----

test_remove_keeps_dir() {
  t_two_profiles
  capart config set default personal
  run claude-apart sync
  run bash -c "printf 'y\n' | claude-apart remove work"
  assert_rc 0 "remove" || return 1
  [ -d "$HOME/.claude-work" ] || { echo "dir deleted"; return 1; }
  assert_eq personal "$(capart config profiles)" "config has no work" || return 1
  [ ! -e "$T/prefix/bin/claude-work" ] || { echo "launcher left"; return 1; }
}

test_remove_unprotected_warning_asks_default_no() {
  t_two_profiles
  capart config set default personal
  run claude-apart sync
  local before; before=$(cat "$XDG_CONFIG_HOME/claude-apart/config")
  run bash -c "printf 'n\n' | claude-apart remove work"
  assert_rc 1 "declined" || return 1
  assert_contains "$ERR" "$HOME/.claude-work will no longer be protected from the other profiles." "warning" || return 1
  assert_eq "$before" "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "unchanged" || return 1
  run claude-apart remove work < /dev/null
  assert_rc 1 "eof" || return 1
  assert_eq "$before" "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "unchanged on eof" || return 1
  grep -q claude-apart "$HOME/.claude-work/settings.json" || { echo "work settings touched"; return 1; }
}

test_remove_adopted_refused_while_others_exist() {
  t_two_profiles
  capart config set default work
  run bash -c "printf 'y\ny\n' | claude-apart remove personal"
  assert_rc 1 "refused" || return 1
  assert_contains "$ERR" "Remove the other profiles first" "message" || return 1
  assert_contains "$(capart config profiles)" "personal" "kept" || return 1
}

test_remove_adopted_ok_when_last() {
  t_two_profiles
  capart config remove-profile work
  capart config set default personal
  run claude-apart remove personal
  assert_rc 0 "last one" || return 1
  [ -d "$HOME/.claude" ] || { echo "dir gone"; return 1; }
}

test_remove_cleans_work_settings_and_resyncs_others() {
  t_two_profiles
  capart config set default personal
  run claude-apart sync
  run bash -c "printf 'y\n' | claude-apart remove work"
  assert_rc 0 "remove" || return 1
  assert_not_contains "$(cat "$HOME/.claude/settings.json")" ".claude-work" "personal has no rule for work" || return 1
  assert_not_contains "$(cat "$HOME/.claude-work/settings.json" 2>/dev/null)" "claude-apart" "work settings cleaned" || return 1
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "can_read" "grant pruned" || return 1
}

test_remove_config_first_when_cleanup_fails() {
  t_two_profiles
  capart config set default personal
  run claude-apart sync
  mv "$HOME/.claude-work/settings.json" "$T/elsewhere.json"
  ln -s "$T/elsewhere.json" "$HOME/.claude-work/settings.json"
  run bash -c "printf 'y\n' | claude-apart remove work"
  [ "$RC" != 0 ] || { echo "expected a failure rc"; return 1; }
  assert_contains "$ERR" "could not clean the settings of work" "message" || return 1
  assert_eq personal "$(capart config profiles)" "config already changed" || return 1
  assert_not_contains "$(cat "$HOME/.claude/settings.json")" ".claude-work" "others still re-synced" || return 1
}

test_remove_default_refused() {
  t_two_profiles
  run claude-apart sync
  run claude-apart remove work
  assert_rc 1 "default refused" || return 1
  assert_contains "$ERR" "is the default profile" "message" || return 1
  assert_contains "$(capart config profiles)" "work" "still there" || return 1
}

test_remove_unknown_profile() {
  t_two_profiles
  run claude-apart remove nope
  assert_rc 1 "unknown" || return 1
}

test_remove_delete_dir_asks_and_deletes() {
  t_two_profiles
  capart config set default personal
  # no to the delete, then no to the warning: nothing changes
  run bash -c "printf 'n\nn\n' | claude-apart remove work --delete-dir"
  assert_rc 1 "declined" || return 1
  [ -d "$HOME/.claude-work" ] || { echo "deleted without yes"; return 1; }
  assert_contains "$(capart config profiles)" work "profile kept" || return 1
  run bash -c "printf 'y\n' | claude-apart remove work --delete-dir"
  assert_rc 0 "remove" || return 1
  [ ! -e "$HOME/.claude-work" ] || { echo "dir still there"; return 1; }
  [ -d "$HOME" ] || return 1
}

test_remove_delete_dir_failed_rm_says_so() { # R67 (5): a failed delete is an error
  t_two_profiles
  capart config set default personal
  mkdir -p "$HOME/.claude-work/locked/sub"
  : > "$HOME/.claude-work/locked/sub/f"
  chmod 555 "$HOME/.claude-work/locked/sub"
  run bash -c "printf 'y\n' | claude-apart remove work --delete-dir"
  chmod 755 "$HOME/.claude-work/locked/sub"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$ERR" "could not delete $HOME/.claude-work." "message" || return 1
  assert_not_contains "$OUT" "Deleted $HOME/.claude-work." "no success line" || return 1
}

test_remove_delete_dir_missing_dir_says_so() {
  t_two_profiles
  capart config set default personal
  rm -rf "$HOME/.claude-work"
  run claude-apart remove work --delete-dir
  assert_rc 0 "remove" || return 1
  assert_contains "$OUT" "no folder" "says nothing to delete" || return 1
  assert_not_contains "$OUT" "was kept" "not kept" || return 1
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

test_remove_delete_dir_refuses_symlink() {
  t_two_profiles
  capart config set default personal
  mkdir -p "$T/real"
  rm -rf "$HOME/.claude-work"; ln -s "$T/real" "$HOME/.claude-work"
  run bash -c "printf 'y\n' | claude-apart remove work --delete-dir"
  [ "$RC" != 0 ] || { echo "symlink: expected failure"; return 1; }
  [ -d "$T/real" ] || { echo "target deleted"; return 1; }
}

test_remove_delete_dir_refuses_overlap_with_other_profile() {
  t_two_profiles
  capart config set default personal
  mkdir -p "$HOME/.claude-work/sub"
  capart config add-profile lab "dir=$HOME/.claude-work/sub" tag=LAB emoji=🟦 colour=blue || return 1
  run bash -c "printf 'y\ny\n' | claude-apart remove work --delete-dir"
  [ "$RC" != 0 ] || { echo "overlap: expected failure"; return 1; }
  assert_contains "$ERR" "overlaps the folder of profile lab" "message" || return 1
  [ -d "$HOME/.claude-work/sub" ] || { echo "nested dir deleted"; return 1; }
  assert_contains "$(capart config profiles)" work "nothing changed" || return 1
}

test_dir_conflict_fails_closed() { # R67 (4): an unreadable owned list or profile list refuses
  t_two_profiles
  local fn='. "$1"; capart() { case "$1 $2" in "$FAIL") echo "boom" >&2; return 1;; esac; perl -I"$CA_ROOT/lib" "$CA_ROOT/libexec/claude-apart/capart.pl" "$@"; }; ca_dir_conflict "$2" "" 0'
  FAIL="config owned" run bash -c "$fn" _ "$REPO/libexec/claude-apart/lib/common.sh" "$HOME/newdir"
  assert_rc 1 "owned failure refuses" || return 1
  FAIL="config profiles" run bash -c "$fn" _ "$REPO/libexec/claude-apart/lib/common.sh" "$HOME/newdir"
  assert_rc 1 "profiles failure refuses" || return 1
  FAIL="none" run bash -c "$fn" _ "$REPO/libexec/claude-apart/lib/common.sh" "$HOME/newdir"
  assert_rc 0 "a free folder still passes" || return 1
  rm -f "$XDG_CONFIG_HOME/claude-apart/config"
  FAIL="config profiles" run bash -c "$fn" _ "$REPO/libexec/claude-apart/lib/common.sh" "$HOME/newdir"
  assert_rc 0 "no config file yet: nothing to overlap" || return 1
}

# Probe 1: a ".." behind a symlink. The check and the delete must see one folder.
test_remove_delete_dir_refuses_dotdot_behind_symlink() {
  t_two_profiles
  capart config set default personal
  mkdir -p "$T/outside/x" "$T/outside/.claude-work"
  : > "$T/outside/.claude-work/.claude.json"
  ln -s "$T/outside/x" "$HOME/a"
  capart config set-profile work dir "$HOME/a/../.claude-work" || return 1
  run bash -c "printf 'y\ny\n' | claude-apart remove work --delete-dir"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  [ -e "$T/outside/.claude-work/.claude.json" ] || { echo "outside folder deleted"; return 1; }
  [ -d "$HOME/.claude-work" ] || { echo "home folder deleted"; return 1; }
}

# Probe 2: another spelling of ~/.claude (case-insensitive disks) is never deleted.
test_remove_delete_dir_refuses_other_case_of_adopted() {
  t_two_profiles
  capart config set default personal
  echo '{}' > "$HOME/.claude/settings.json"   # looks like a config folder, so only the path check can stop it
  capart config set-profile work dir '~/.CLAUDE' || return 1
  run bash -c "printf 'y\ny\n' | claude-apart remove work --delete-dir"
  [ -f "$HOME/.claude.json" ] && [ -d "$HOME/.claude" ] || { echo "adopted folder damaged"; return 1; }
  if [ -d "$HOME/.CLAUDE" ]; then
    [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  fi
}

test_remove_refused_in_session() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart remove work
  assert_rc 1 "refused" || return 1
}

# ---- add: folder clashes, injection, duplicates, messages ----

_add_refused() { # <args...>: add must fail, run no login, change nothing
  local before; before=$(cat "$XDG_CONFIG_HOME/claude-apart/config")
  run claude-apart add "$@" < /dev/null
  [ "$RC" != 0 ] || { echo "accepted: $*"; return 1; }
  assert_eq "$before" "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "config unchanged for: $*" || return 1
  [ ! -e "$FAKE_LOG" ] || { echo "login ran for: $*"; return 1; }
}

test_add_refuses_dir_clashes() {
  t_two_profiles
  export FAKE_LOGIN_EMAIL=n@example.com FAKE_LOGIN_ORG=org-n
  mkdir -p "$HOME/box/lab"
  capart config add-profile lab "dir=$HOME/box/lab" tag=LAB emoji=🟦 colour=blue || return 1
  _add_refused n --dir "$HOME/.claude-work/." || return 1
  _add_refused n --dir "$HOME/x/../y" || return 1
  _add_refused n --dir "$HOME/.claude-work/.." || return 1
  _add_refused n --dir '~/.CLAUDE' || return 1
  _add_refused n --dir "$HOME/./.claude" || return 1
  _add_refused n --dir "$HOME/.claude/sub" || return 1
  _add_refused n --dir "$HOME/.claude-work/sub" || return 1
  _add_refused n --dir "$HOME/box" || return 1
  _add_refused n --dir "$HOME" || return 1
}

test_add_adopt_refuses_duplicate_account() {
  t_two_profiles
  capart config remove-profile personal
  capart config set default work
  t_login_as "$HOME/.claude.json" w@example.com org-w   # ~/.claude holds work's account
  run bash -c "printf '\n\ny\n' | claude-apart add personal --adopt"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$ERR" "already used by profile work" "message" || return 1
  assert_not_contains "$OUT$ERR" "w@example.com" "no email" || return 1
  assert_eq work "$(capart config profiles)" "rolled back" || return 1
  [ ! -e "$FAKE_LOG" ] || { echo "logout ran on the existing login"; return 1; }
  assert_contains "$(cat "$HOME/.claude.json")" w@example.com "login kept" || return 1
}

test_add_rejects_control_characters() {
  t_two_profiles
  _add_refused n --emoji $'E\ncan_read = personal' || return 1
  _add_refused n --colour $'blue\n[profile x]' || return 1
  _add_refused n --tag $'T\nx' || return 1
  _add_refused n --dir $'/tmp/a\nb' || return 1
  _add_refused $'ok\nbad' || return 1
  run capart config add-profile n 'emoji=E
can_read = personal'
  [ "$RC" != 0 ] || { echo "capart accepted a newline"; return 1; }
  run capart config set-profile work emoji $'E\nX'
  [ "$RC" != 0 ] || { echo "set-profile accepted a newline"; return 1; }
  assert_not_contains "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "can_read = personal" "no injected line" || return 1
}

test_add_name_checked_before_prompts() {
  t_two_profiles
  run bash -c "printf 'EMOJI\n' | claude-apart add Bad"
  [ "$RC" != 0 ] || return 1
  assert_not_contains "$ERR" "Emoji for" "no prompt before the name check" || return 1
}

test_set_fields_is_all_or_nothing() {
  t_two_profiles
  local before; before=$(cat "$XDG_CONFIG_HOME/claude-apart/config")
  run capart config set-fields work.email=a@example.com work.bogus=1
  [ "$RC" != 0 ] || return 1
  assert_eq "$before" "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "unchanged" || return 1
}

test_add_tag_default_is_four_characters() {
  t_two_profiles
  capart config add-profile longername || return 1
  assert_eq LONG "$(_cfg_value longername TAG)" "config default" || return 1
}

test_add_sync_failure_has_own_rc_and_message() {
  t_two_profiles
  run claude-apart sync
  mv "$HOME/.claude/settings.json" "$T/elsewhere.json"
  ln -s "$T/elsewhere.json" "$HOME/.claude/settings.json"
  export FAKE_LOGIN_EMAIL=n@example.com FAKE_LOGIN_ORG=org-n
  run bash -c "printf '\n\ny\n' | claude-apart add lab"
  assert_rc 3 "added but sync failed" || return 1
  assert_contains "$ERR" "was added, but the sync failed" "message" || return 1
  assert_contains "$(capart config profiles)" lab "profile exists" || return 1
  # setup's wording for the same case
  capart config remove-profile lab
  run bash -c "printf 'add\nlab\n\n\ny\ndone\n' | claude-apart setup"
  assert_contains "$OUT" "Profile added; run claude-apart sync" "setup wording" || return 1
  assert_not_contains "$OUT" "Profile not added." "not the failure text" || return 1
}

# ---- login ----

test_login_failed_login_logs_out() {
  _work_unlogged || return 1
  export FAKE_LOGIN_EMAIL=w2@example.com FAKE_LOGIN_ORG=org-w2 FAKE_RC=1
  run bash -c "printf 'y\n' | claude-apart login work"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$(cat "$FAKE_LOG")" "auth logout" "logged out after a failed login" || return 1
}

test_login_uses_profile_temp_folder() {
  _work_unlogged || return 1
  export FAKE_LOGIN_EMAIL=w2@example.com FAKE_LOGIN_ORG=org-w2
  run bash -c "printf 'y\n' | claude-apart login work"
  local tmp="$XDG_STATE_HOME/claude-apart/tmp/work"
  assert_contains "$(cat "$FAKE_LOG")" "TMPDIR_CC=$tmp" "CLAUDE_CODE_TMPDIR set" || return 1
  assert_eq 700 "$(perl -e 'printf "%o", (stat shift)[2] & 0777' "$tmp")" "mode" || return 1
}

# ---- setup ----

test_setup_menu_grants_eof_changes_nothing() {
  t_two_profiles
  local before; before=$(cat "$XDG_CONFIG_HOME/claude-apart/config")
  # first answer given, then the input ends
  run bash -c "printf 'grants\nn\n' | claude-apart setup"
  assert_rc 1 "eof" || return 1
  assert_eq "$before" "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "config unchanged" || return 1
  [ ! -e "$HOME/.claude/settings.json" ] || { echo "synced after eof"; return 1; }
}

test_setup_fresh_without_claude_json_offers_adopt_and_logs_in() {
  t_two_profiles
  rm -f "$XDG_CONFIG_HOME/claude-apart/config" "$HOME/.claude.json"
  rm -rf "$HOME/.claude-work"
  export FAKE_LOGIN_EMAIL=p@example.com FAKE_LOGIN_ORG=org-p
  # adopt y, name, emoji, colour, confirm | no more | default
  run bash -c "printf 'y\n\n\n\ny\n\n\n' | claude-apart setup"
  assert_rc 0 "setup" || return 1
  assert_contains "$OUT$ERR" "Adopt ~/.claude" "offer shown" || return 1
  assert_contains "$(cat "$FAKE_LOG")" "CONFIG_DIR=<unset> PROFILE= ARGS=auth login" "login for ~/.claude" || return 1
  assert_eq p@example.com "$(_cfg_value personal EMAIL)" "recorded" || return 1
}

# ---- round 2 ----

test_add_refuses_trailing_space_dirs() {
  t_two_profiles
  export FAKE_LOGIN_EMAIL=n@example.com FAKE_LOGIN_ORG=org-n
  _add_refused n --dir "$HOME/.claude " || return 1
  _add_refused n --dir "$HOME/.claude-work " || return 1
  _add_refused n --dir " $HOME/x" || return 1
  [ -f "$HOME/.claude.json" ] && assert_contains "$(cat "$HOME/.claude.json")" p@example.com "identity file untouched" || return 1
  run capart config add-profile n "dir=$HOME/.claude "
  [ "$RC" != 0 ] || { echo "capart accepted an edge space"; return 1; }
}

test_add_refuses_owned_path_overlaps() {
  t_two_profiles
  export FAKE_LOGIN_EMAIL=n@example.com FAKE_LOGIN_ORG=org-n
  capart config set-profile personal protect "$HOME/notes/private" || return 1
  _add_refused n --dir "$HOME/notes" || return 1
  _add_refused n --dir "$HOME/.claude.json.d" || return 1
  _add_refused n --dir "$XDG_STATE_HOME/claude-apart/tmp/personal" || return 1
}

test_remove_delete_dir_refuses_other_profiles_protect_path() {
  t_two_profiles
  capart config set default personal
  mkdir -p "$HOME/notes/private"; echo '{}' > "$HOME/notes/settings.json"
  capart config set-profile personal protect "$HOME/notes/private" || return 1
  capart config set-profile work dir "$HOME/notes" || return 1
  run bash -c "printf 'y\ny\n' | claude-apart remove work --delete-dir"
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  [ -d "$HOME/notes/private" ] || { echo "protected folder deleted"; return 1; }
}

test_add_root_dir_gets_a_clear_message() {
  t_two_profiles
  run claude-apart add n --dir / < /dev/null
  assert_rc 1 "refused" || return 1
  assert_contains "$ERR" "cannot be /" "message" || return 1
  assert_not_contains "$ERR" "usage" "not the capart usage text" || return 1
}

# ---- R65 ----

test_session_refuses_every_config_and_settings_write() {
  t_two_profiles
  local before; before=$(cat "$XDG_CONFIG_HOME/claude-apart/config")
  local c
  for c in "config set default personal" "config set-fields work.can_read=personal" \
           "config set-profile work can_read personal" "config add-profile n" \
           "config remove-profile personal" "profile-remove personal" \
           "settings install --profile work" "settings uninstall --profile personal"; do
    _in_work_session capart $c
    [ "$RC" = 1 ] || { echo "not refused (rc $RC): $c"; return 1; }
    assert_contains "$ERR" "cannot run inside Claude" "message for: $c" || return 1
  done
  assert_eq "$before" "$(cat "$XDG_CONFIG_HOME/claude-apart/config")" "config unchanged" || return 1
  [ ! -e "$HOME/.claude/settings.json" ] || { echo "settings written"; return 1; }
}

test_outside_session_the_same_writes_work() {
  t_two_profiles
  run capart config set-fields work.can_read=personal
  assert_rc 0 "set-fields" || return 1
  run capart settings install --profile work
  assert_rc 0 "settings install" || return 1
  run capart profile-remove personal
  assert_rc 0 "profile-remove" || return 1
}

test_session_identity_check_only_own() {
  t_two_profiles
  _in_work_session capart identity-check personal
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_not_contains "$OUT$ERR" "p@example.com" "no other email" || return 1
  _in_work_session capart identity-check work
  assert_rc 0 "own" || return 1
}

test_session_statusline_only_own() { # R67 (1): statusline --profile follows R63 too
  t_two_profiles
  _in_work_session capart statusline --profile personal </dev/null
  [ "$RC" != 0 ] || { echo "expected refusal"; return 1; }
  assert_not_contains "$OUT$ERR" "p@example.com" "no other email" || return 1
  _in_work_session capart statusline --profile work </dev/null
  assert_rc 0 "own" || return 1
  assert_contains "$OUT" "w@example.com" "own status line" || return 1
  run capart statusline --profile personal </dev/null
  assert_rc 0 "outside a session any profile" || return 1
}

test_guard_blocks_running_capart() {
  t_two_profiles
  # R67 (6): a copy outside the repo (the repo is the tool root, where R26 alone would block)
  local c cap="$HOME/elsewhere/libexec/claude-apart/capart.pl" cwd="$HOME/proj"
  mkdir -p "$cwd" "${cap%/*}"
  for c in "perl ~/x/libexec/claude-apart/capart.pl config set-fields work.can_read=personal" \
           "xargs perl $cap config set-fields a.b=c" "$cap config set default work" \
           "cd /tmp && ./capart.pl status" "env perl -I lib $cap status" "bash $cap" \
           "find . -exec perl $cap status ;" "echo x | xargs $cap" "FOO=1 perl $cap status" \
           "perl -n $cap" "perl -p $cap" "perl -Mautodie $cap" "perl -ie 1 $cap" "python3 x.py $cap" \
           "ruby -E utf-8 $cap" "node --inspect $cap" "perl -e 1 perl $cap"; do
    pre_tool work Bash "{\"command\":$(_json_str "$c")}" "$cwd"
    assert_rc 2 "blocked: $c" || return 1
  done
}

test_guard_capart_as_data_after_program_option() { # R67 (2) as corrected
  t_two_profiles
  local c cap="$HOME/elsewhere/libexec/claude-apart/capart.pl" cwd="$HOME/proj"
  mkdir -p "$cwd" "${cap%/*}"
  for c in "perl -ne 'print if /session/' $cap" "perl -lne 'print' $cap" "perl -E 'say 1' $cap" \
           "ruby -e 'puts ARGF.read.size' $cap" "node -e 'console.log(1)' $cap" \
           "python3 -c 'import sys; print(sys.argv)' $cap"; do
    pre_tool work Bash "{\"command\":$(_json_str "$c")}" "$cwd"
    assert_rc 0 "allowed: $c" || return 1
  done
}

test_guard_shell_c_words_may_run_capart() { # R76: a shell's -c program can run $0 and $@
  t_two_profiles
  local c cap="$HOME/elsewhere/libexec/claude-apart/capart.pl" cwd="$HOME/proj"
  mkdir -p "$cwd" "${cap%/*}"
  for c in "bash -c $cap" "sh -c '\"\$0\" settings uninstall --profile personal' $cap" \
           "bash -c 'wc -l \"\$0\"' $cap" "sh -ec true $cap"; do
    pre_tool work Bash "{\"command\":$(_json_str "$c")}" "$cwd"
    assert_rc 2 "blocked: $c" || return 1
  done
}

test_guard_allows_plain_capart_mentions() {
  t_two_profiles
  local c cap="$REPO/libexec/claude-apart/capart.pl"
  for c in "git add libexec/claude-apart/capart.pl" "grep -n session_allow libexec/claude-apart/capart.pl" \
           "cat $cap" "ls -l $cap" "wc -l capart.pl"; do
    pre_tool work Bash "{\"command\":$(_json_str "$c")}"
    assert_rc 0 "allowed: $c" || return 1
  done
}

# ---- R66 ----

test_tool_tree_is_write_denied_for_every_profile() {
  t_two_profiles
  local root; root=$(cd "$REPO" && pwd -P)
  local p
  for p in work personal; do
    pre_tool $p Edit "{\"file_path\":\"$root/lib/ClaudeApart/Guard.pm\",\"old_string\":\"a\",\"new_string\":\"b\"}"
    assert_rc 2 "$p Edit" || return 1
    pre_tool $p Write "{\"file_path\":\"$root/lib/ClaudeApart/Guard.pm\",\"content\":\"x\"}"
    assert_rc 2 "$p Write" || return 1
    pre_tool $p Read "{\"file_path\":\"$root/lib/ClaudeApart/Guard.pm\"}"
    assert_rc 0 "$p Read" || return 1
  done
  run claude-apart sync
  assert_contains "$(cat "$HOME/.claude-work/settings.json")" "Edit(/$root/**)" "deny rule in work settings" || return 1
  assert_contains "$(cat "$HOME/.claude/settings.json")" "Edit(/$root/**)" "deny rule in personal settings" || return 1
}
