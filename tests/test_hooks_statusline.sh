# Tests for the identity check in the hooks, the Herdr labels at session
# start, and the status line. The real herdr is never run: tests use a stub.

CAPART="$REPO/libexec/claude-apart/capart.pl"

_wrong_identity() { # the work login now belongs to someone else
  t_two_profiles
  t_login_as "$HOME/.claude-work/.claude.json" p@example.com org-p
}

_statusline() { # <profile> [--chain cmd]: stdin is a status JSON
  local p=$1; shift
  run perl -I"$REPO/lib" "$CAPART" statusline --profile "$p" "$@" <<<'{"model":"x"}'
}

# Records every call in $T/herdr.log; answers get for w1 (label $WS_LABEL)
# and tab w1:t1 (label $TAB_LABEL).
_herdr_labels_stub() { # <workspace label> <tab label>
  cat > "$T/bin/herdr" <<STUB
#!/bin/bash
echo "\$*" >> "$T/herdr.log"
case "\$*" in
  "workspace get w1") printf '{"result":{"type":"workspace_info","workspace":{"label":"%s","workspace_id":"w1"}}}\n' '$1' ;;
  "tab get w1:t1") printf '{"result":{"tab":{"label":"%s","tab_id":"w1:t1","workspace_id":"w1"},"type":"tab_info"}}\n' '$2' ;;
  *rename*) echo '{"result":{"type":"ok"}}' ;;
  *) echo '{"error":{"code":"x"}}' >&2; exit 1 ;;
esac
STUB
  chmod +x "$T/bin/herdr"
}

_session_start() { # <profile>
  export HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HERDR_TAB_ID=w1:t1
  hook "$1" session-start '{"hook_event_name":"SessionStart"}'
}

_renames() { grep rename "$T/herdr.log" 2>/dev/null; true; }

_now_s() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# Fails when a process whose whole command line is <cmd> is running.
_no_proc() {
  ps -axo command | grep -qx "$1" && { _assert_fail "no process left behind" "$1 is running"; return 1; }
  return 0
}

# A herdr stub that sleeps <n> s on the calls matching <pattern>, answering others at once.
_herdr_slow_stub() { # <workspace label> <tab label> <slow pattern> <seconds>
  cat > "$T/bin/herdr" <<STUB
#!/bin/bash
echo "\$*" >> "$T/herdr.log"
case "\$*" in
  $3) exec sleep $4 ;;
  "workspace get w1") printf '{"result":{"workspace":{"label":"%s"}}}\n' '$1' ;;
  "tab get w1:t1") printf '{"result":{"tab":{"label":"%s"}}}\n' '$2' ;;
  *) echo '{}' ;;
esac
STUB
  chmod +x "$T/bin/herdr"
}

test_prompt_blocked_on_wrong_identity() {
  _wrong_identity
  hook work prompt '{"prompt":"x"}'
  assert_rc 2 "prompt blocked" || return 1
  assert_contains "$ERR" "claude-apart login work" "tells how to log in" || return 1
  assert_not_contains "$ERR" "p@example.com" "no email in the block" || return 1
  t_two_profiles
  hook work prompt '{"prompt":"x"}'
  assert_rc 0 "prompt allowed when the login matches" || return 1
}

test_prompt_at_mention_of_denied_path_blocked() { # F9: @-mentions are read by Claude Code itself
  t_two_profiles
  mkdir -p "$HOME/proj/src"
  local cwd; cwd=$(_json_str "$HOME/proj")
  hook work prompt "{\"prompt\":\"look at @~/.claude/CLAUDE.md\",\"cwd\":$cwd}"
  assert_rc 2 "@ of the adopted folder" || return 1
  assert_contains "$ERR" "claude-apart: blocked — the prompt mentions @~/.claude/CLAUDE.md, which this profile may not read." "names the path" || return 1
  hook work prompt "{\"prompt\":\"read @\\\"~/.claude/my notes.md\\\" now\",\"cwd\":$cwd}"
  assert_rc 2 "quoted @ with spaces" || return 1
  hook work prompt "{\"prompt\":\"@../.claude.json, please\",\"cwd\":$cwd}"
  assert_rc 2 "relative @ into the identity file" || return 1
  hook work prompt "{\"prompt\":\"email me@example.com\",\"cwd\":$cwd}"
  assert_rc 0 "an email is not a mention" || return 1
  hook work prompt "{\"prompt\":\"fix @src/x.rb\",\"cwd\":$cwd}"
  assert_rc 0 "own project file" || return 1
  hook work prompt "{\"prompt\":\"what is in ~/.claude/CLAUDE.md\",\"cwd\":$cwd}"
  assert_rc 0 "plain mention without @ passes (the guard stops the tool calls)" || return 1
  hook personal prompt "{\"prompt\":\"look at @~/.claude-work/CLAUDE.md\",\"cwd\":$cwd}"
  assert_rc 0 "personal may read work (can_read)" || return 1
  hook personal prompt "{\"prompt\":\"look at @~/.config/claude-apart/config\",\"cwd\":$cwd}"
  assert_rc 2 "the config folder is denied to every profile" || return 1
}

test_pre_tool_blocked_on_wrong_identity() {
  _wrong_identity
  mkdir -p "$HOME/.claude-work"; echo hi > "$HOME/.claude-work/note"
  pre_tool work Read "{\"file_path\":\"$HOME/.claude-work/note\"}"
  assert_rc 2 "pre-tool blocked" || return 1
  assert_contains "$ERR" "claude-apart login work" "identity text" || return 1
  assert_not_contains "$ERR" "p@example.com" "no email in the block" || return 1
  rm "$HOME/.claude-work/.claude.json"    # missing login blocks too
  pre_tool work Read "{\"file_path\":\"$HOME/.claude-work/note\"}"
  assert_rc 2 "pre-tool blocked without a login" || return 1
}

test_session_start_labels_once() {
  t_two_profiles
  _herdr_labels_stub 'project' 'build'
  _session_start work
  assert_rc 0 "never blocks" || return 1
  assert_eq "🟧 WORK · project" "$(_renames | sed -n 's/^workspace rename w1 //p')" "workspace renamed once" || return 1
  assert_eq "🟧 build" "$(_renames | sed -n 's/^tab rename w1:t1 //p')" "tab renamed once" || return 1
  assert_eq 2 "$(_renames | wc -l | tr -d ' ')" "two renames in all" || return 1
  rm "$T/herdr.log"
  _herdr_labels_stub '🟧 WORK · project' '🟧 build'
  _session_start work
  assert_rc 0 "second start" || return 1
  assert_eq "" "$(_renames)" "no rename when already labelled" || return 1
  _herdr_labels_stub '🟪 PERS · x' '🟧 t'
  _session_start work
  assert_rc 0 "other profile's workspace" || return 1
  assert_eq "" "$(_renames)" "no rename of a foreign workspace" || return 1
  assert_contains "$OUT" "belongs to another profile" "says so" || return 1
}

test_session_start_never_blocks() {
  t_two_profiles
  _wrong_identity
  # wrong login: a message on stdout, still rc 0, no email
  printf '#!/bin/bash\nexit 1\n' > "$T/bin/herdr"; chmod +x "$T/bin/herdr"
  _session_start work
  assert_rc 0 "wrong login" || return 1
  assert_contains "$OUT" '"systemMessage"' "json message" || return 1
  assert_contains "$OUT" "claude-apart login work" "identity text" || return 1
  assert_not_contains "$OUT" "p@example.com" "no email" || return 1
  t_two_profiles
  _session_start work
  assert_rc 0 "herdr fails" || return 1
  assert_eq "" "$OUT" "quiet when ok" || return 1
  hook nosuch session-start 'not json'
  assert_rc 0 "unknown profile and bad input" || return 1
  rm "$T/bin/herdr"
  _session_start work
  assert_rc 0 "no herdr at all" || return 1
}

test_session_start_says_why_the_setup_failed() { # F14: the user learns why every tool call will block
  t_two_profiles
  hook nosuch session-start '{"hook_event_name":"SessionStart"}'
  assert_rc 0 "still exit 0" || return 1
  assert_contains "$OUT" '"systemMessage"' "json message" || return 1
  assert_contains "$OUT" "unknown profile" "the reason" || return 1
  printf 'protect = ~/a\nprotect = ~/b\n' >> "$XDG_CONFIG_HOME/claude-apart/config"
  hook work session-start '{"hook_event_name":"SessionStart"}'
  assert_rc 0 "still exit 0" || return 1
  assert_contains "$OUT" "duplicate key 'protect' in [profile work] at line 18" "config reason" || return 1
  rm "$XDG_CONFIG_HOME/claude-apart/config"
  hook work session-start '{"hook_event_name":"SessionStart"}'
  assert_rc 0 "no config" || return 1
  assert_contains "$OUT" '"systemMessage"' "missing config is reported" || return 1
}

test_statusline_badge() {
  t_two_profiles
  _statusline work
  assert_rc 0 "rc" || return 1
  assert_contains "$OUT" "48;5;208m" "colour" || return 1
  assert_contains "$OUT" " WORK " "tag" || return 1
  assert_contains "$OUT" "w@example.com" "email" || return 1
}

test_statusline_wrong_account() {
  _wrong_identity
  _statusline work
  assert_rc 0 "rc" || return 1
  assert_contains "$OUT" "WRONG ACCOUNT" "warning" || return 1
  assert_contains "$OUT" "48;5;196m" "red" || return 1
  rm "$HOME/.claude-work/.claude.json"
  _statusline work
  assert_contains "$OUT" "not logged in" "missing login" || return 1
}

test_statusline_chain() {
  t_two_profiles
  _statusline work --chain 'printf "orig\nline2"'
  assert_eq "line2" "$(printf '%s\n' "$OUT" | sed -n 2p)" "line 2 unchanged" || return 1
  case "$(printf '%s\n' "$OUT" | sed -n 1p)" in *"│ orig") ;; *) _assert_fail "line 1 ends with the chain" "$OUT"; return 1;; esac
  _statusline work --chain 'cat'
  assert_contains "$OUT" '│ {"model":"x"}' "chain gets the same stdin" || return 1
  _statusline work --chain 'exit 3'
  assert_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "failing chain dropped" || return 1
  local t0 t1
  t0=$(_now_s)
  _statusline work --chain 'sleep 4.71; :'
  t1=$(_now_s)
  perl -e 'exit($ARGV[1] - $ARGV[0] < 3 ? 0 : 1)' "$t0" "$t1" || { _assert_fail "hung chain returns in < 3 s" "$t0 $t1"; return 1; }
  assert_contains "$OUT" " WORK " "badge still shown" || return 1
  assert_not_contains "$OUT" "│" "no chain part" || return 1
  sleep 0.3
  _no_proc "sleep 4.71" || return 1
  return 0
}

# Each shape used to reach the 5 s supervisor kill (rc 2).
_slow_case() { # <workspace label> <tab label> <slow pattern> <seconds> <msg>
  local t0 t1
  _herdr_slow_stub "$1" "$2" "$3" "$4"
  t0=$(_now_s)
  _session_start work
  t1=$(_now_s)
  assert_rc 0 "$5: rc" || return 1
  perl -e 'exit($ARGV[1] - $ARGV[0] < 4.3 ? 0 : 1)' "$t0" "$t1" || { _assert_fail "$5: ends well under 5 s" "$t0 $t1"; return 1; }
}

test_session_start_slow_herdr_deadline() {
  t_two_profiles
  _slow_case 'project' 'build' '"workspace rename"*' 20 "hung workspace rename" || return 1
  _slow_case '🟧 WORK · project' 'build' '"tab get"*' 20 "hung tab get" || return 1
  _slow_case '🟧 WORK · project' '🟧 build' '"workspace get"*' 20 "hung workspace get" || return 1
  # slow lookup, then a hung rename: the shared deadline covers both
  cat > "$T/bin/herdr" <<STUB
#!/bin/bash
case "\$*" in
  "workspace get w1") sleep 2.5; echo '{"result":{"workspace":{"label":"project"}}}' ;;
  "workspace rename"*) exec sleep 20 ;;
  *) echo '{}' ;;
esac
STUB
  chmod +x "$T/bin/herdr"
  t_login_as "$HOME/.claude-work/.claude.json" p@example.com org-p
  local t0 t1
  t0=$(_now_s); _session_start work; t1=$(_now_s)
  assert_rc 0 "slow get then hung rename" || return 1
  perl -e 'exit($ARGV[1] - $ARGV[0] < 4.3 ? 0 : 1)' "$t0" "$t1" || { _assert_fail "under 5 s" "$t0 $t1"; return 1; }
  assert_contains "$OUT" "claude-apart login work" "identity message still printed" || return 1
}

test_session_start_empty_tab_label_once() {
  t_two_profiles
  _herdr_labels_stub '🟧 WORK · project' ''
  _session_start work
  assert_eq 1 "$(_renames | grep -c '^tab rename')" "first start renames the empty tab" || return 1
  _herdr_labels_stub '🟧 WORK · project' '🟧'
  _session_start work
  assert_eq 1 "$(_renames | grep -c '^tab rename')" "a tab that is only the emoji is left alone" || return 1
}

test_session_start_other_profile_no_tab_rename() {
  t_two_profiles
  _herdr_labels_stub '🟪 PERS · x' 'build'
  _session_start work
  assert_rc 0 "rc" || return 1
  assert_eq "" "$(_renames)" "no workspace or tab rename" || return 1
  assert_contains "$OUT" "belongs to another profile" "message" || return 1
}

test_statusline_chain_dies_with_status_line() {
  t_two_profiles
  perl -I"$REPO/lib" "$CAPART" statusline --profile work --chain 'sleep 4.72; :' <<<'{}' >/dev/null 2>&1 &
  local pid=$!
  sleep 0.6
  _no_proc "sleep 4.72" >/dev/null 2>&1 && { _assert_fail "chain should be running" "not found"; return 1; }
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  sleep 0.3
  _no_proc "sleep 4.72" || return 1
}
