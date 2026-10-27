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
  t0=$(date +%s)
  _statusline work --chain 'sleep 5'
  t1=$(date +%s)
  [ $((t1 - t0)) -lt 3 ] || { _assert_fail "hung chain returns in < 3 s" "$((t1 - t0)) s"; return 1; }
  assert_contains "$OUT" " WORK " "badge still shown" || return 1
  assert_not_contains "$OUT" "│" "no chain part" || return 1
  sleep 0.3
  ps -axo command | grep -v grep | grep -q '^sleep 5' && { _assert_fail "no sleep left behind" "sleep 5 running"; return 1; }
  return 0
}
