# Tests for the guard's launcher, env and Herdr rules, the in-session refusal
# of `claude-apart`, and the hook supervisor's process-group kill.
# The real herdr is never run: every test puts a stub on PATH.

LH_BLOCK='claude-apart: blocked — this touches another profile.'
LH_ERROR='claude-apart: guard error — blocked to be safe.'

_run_bash() { # <profile> <command> [cwd]: the hook for a Bash call
  pre_tool "$1" Bash "{\"command\":$(_json_str "$2")}" "$3"
}

_expect_block() { # <msg>
  assert_rc 2 "$1" || return 1
  assert_eq "$LH_BLOCK" "$ERR" "$1: only the block text" || return 1
}

_expect_allow() { # <msg>
  assert_rc 0 "$1" || return 1
  assert_eq "" "$OUT$ERR" "$1: no output" || return 1
}

_expect_guard_error() { # <msg>
  assert_rc 2 "$1" || return 1
  assert_eq "$LH_ERROR" "$ERR" "$1: only the guard error text" || return 1
}

_blocks() { # <profile> <command>...: each command is blocked
  local p=$1 c; shift
  for c in "$@"; do _run_bash "$p" "$c"; _expect_block "$p: $c" || return 1; done
}

_allows() { # <profile> <command>...: each command is allowed
  local p=$1 c; shift
  for c in "$@"; do _run_bash "$p" "$c"; _expect_allow "$p: $c" || return 1; done
}

_now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

# The standard Herdr stub: w1 is work, w2 is personal, w3 has no profile
# label; agent "rev" sits in w2, agent "me" in w1. Every call is logged.
_herdr_std() {
  cat > "$T/bin/herdr" <<'STUB'
#!/bin/bash
echo "$*" >> "$T/herdr.calls"
ws() { printf '{"id":"cli:workspace:get","result":{"type":"workspace_info","workspace":{"label":"%s","workspace_id":"%s"}}}\n' "$2" "$1"; }
agent() { printf '{"result":{"agent":{"pane_id":"%s:p1","tab_id":"%s:t1","workspace_id":"%s"},"type":"agent_info"}}\n' "$1" "$1" "$1"; }
case "$*" in
  "workspace get w1") ws w1 '🟧 WORK · project' ;;
  "workspace get w2") ws w2 '🟪 PERS · ideas' ;;
  "workspace get w3") ws w3 'scratch' ;;
  "agent get rev") agent w2 ;;
  "agent get me") agent w1 ;;
  *) echo '{"error":{"code":"not_found","message":"not found"}}' >&2; exit 1 ;;
esac
STUB
  chmod +x "$T/bin/herdr"
}

_herdr_script() { # <bash body>: a custom stub
  printf '#!/bin/bash\n%s\n' "$1" > "$T/bin/herdr"
  chmod +x "$T/bin/herdr"
}

_all_gone() { # <pid file>: every pid in it has exited (waits up to 3 s each)
  local p i
  for p in $(cat "$1"); do
    i=0
    while kill -0 "$p" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 30 ]; then echo "process $p still alive"; kill -9 "$p" 2>/dev/null; return 1; fi
      sleep 0.1
    done
  done
}

# ---- launchers ------------------------------------------------------------------

test_work_cannot_start_personal_launcher() {
  t_two_profiles
  _blocks work 'claude-personal -p hi' 'CLAUDE_CONFIG_DIR=$HOME/.claude claude' \
    'CLAUDE_APART_PROFILE=personal claude -p x' || return 1
}

test_plain_claude_and_own_launcher_allowed() {
  t_two_profiles
  _allows work 'claude -p x' 'claude-work -p x' 'claude-nope -p x' 'which claude' || return 1
  _allows personal 'claude -p x' 'claude-personal -p x' || return 1
}

test_personal_cannot_start_work() {
  t_two_profiles
  _blocks personal 'claude-work -p x' || return 1
}

test_launcher_spellings_blocked() { # any word or piece whose name is another profile's launcher
  t_two_profiles
  _blocks personal '/usr/local/bin/claude-work -p x' 'nohup claude-work -p x &' \
    'bash -c "claude-work -p x"' 'X=claude-work; $X -p x' 'CLAUDE-WORK -p x' \
    'echo hi | xargs claude-work -p' '"$(command -v claude-work)" -p x' \
    'timeout 5 \claude-work' 'env --chdir=/tmp claude-work' 'ls; claude-work' || return 1
}

# ---- claude-apart ---------------------------------------------------------------

test_copy_blocked_in_session() {
  t_two_profiles
  _blocks work 'claude-apart copy personal work' || return 1
  _blocks personal 'claude-apart copy personal work' || return 1
}

test_claude_apart_allowlist() { # R42: a known subcommand outside the allowlist, or an option
  t_two_profiles
  _allows work 'claude-apart status' 'claude-apart check' 'claude-apart help' 'claude-apart -h' \
    'claude-apart --help' 'claude-apart new work ideas' 'claude-apart new work --cwd /tmp' \
    'which claude-apart' 'command -v claude-apart' 'type claude-apart' \
    'git add bin/claude-apart README.md' 'git add bin/claude-apart lib/x tests/y.sh' \
    'shellcheck bin/claude-apart libexec/claude-apart/wrapper.sh' 'claude-apart frobnicate' 'claude-apart' || return 1
  _blocks work 'claude-apart --version' 'xargs claude-apart' 'echo sync | xargs claude-apart' \
    'claude-apart new personal ideas' 'claude-apart new' 'claude-apart remove personal' \
    'claude-apart sync' 'claude-apart add extra' 'claude-apart login work' 'claude-apart setup' \
    'claude-apart uninstall' 'claude-apart copy personal work' '/opt/x/bin/claude-apart sync' \
    'claude-apart "$(echo copy)" personal work' 'claude-apart status && claude-apart sync' \
    'bash -c "claude-apart sync"' 'CLAUDE-APART sync' 'c=claude-apart; $c sync' \
    'claude-apart ${X%/}' 'claude-apart "sy"nc' || return 1
  _allows personal 'claude-apart new personal' || return 1
  _blocks personal 'claude-apart new work' || return 1
}

test_cli_refuses_in_session() {
  local s want='claude-apart: run this in a normal terminal, not inside Claude.'
  for s in setup add remove login copy sync uninstall; do
    CLAUDE_CODE_CHILD_SESSION=1 run claude-apart "$s" x
    assert_rc 1 "$s in a session" || return 1
    assert_eq "$want" "$ERR" "$s: message" || return 1
  done
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart help
  assert_rc 0 "help in a session" || return 1
  run claude-apart copy a b
  assert_not_contains "$ERR" "normal terminal" "copy outside a session" || return 1
}

# ---- env tokens -----------------------------------------------------------------

test_env_tokens_blocked() { # any mention, except an assignment that names the own profile
  t_two_profiles
  _blocks work 'unset CLAUDE_CONFIG_DIR; claude' 'env -u CLAUDE_CONFIG_DIR claude -p x' \
    'echo $CLAUDE_APART_PROFILE' 'echo "${CLAUDE_CONFIG_DIR:-none}"' 'export CLAUDE_CODE_CHILD_SESSION=0' \
    'CLAUDE_CODE_CHILD_SESSION= claude -p x' 'CLAUDE_CONFIG_DIR=/tmp/x claude' \
    'CLAUDE_CONFIG_DIR=.claude-work claude' 'CLAUDE_CONFIG_DIR= claude' \
    'CLAUDE_CONFIG_DIR=~/.claude-work/../x claude' 'CLAUDE_CONFIG_DIR=$NOPE claude' \
    'CLAUDE_APART_PROFILE=$CLAUDE_APART_PROFILE claude' 'CLAUDE_APART_PROFILE=Work claude' \
    'CLAUDE_"CONFIG"_DIR=/tmp/x claude' "X=\$'\\x43LAUDE_APART_PROFILE' env" \
    'bash -c "CLAUDE_APART_PROFILE=personal claude"' 'CLAUDE_APART_PROFILE+=x claude' \
    'export CLAUDE_APART_PROFILE' 'cat <<EOF
CLAUDE_CONFIG_DIR=/tmp/x
EOF' || return 1
  _blocks personal 'CLAUDE_APART_PROFILE=work claude' 'CLAUDE_CONFIG_DIR=~/.claude-work claude' || return 1
}

test_env_own_assignment_allowed() {
  t_two_profiles
  _allows work 'CLAUDE_CONFIG_DIR=~/.claude-work claude -p x' 'CLAUDE_CONFIG_DIR=$HOME/.claude-work/ claude' \
    'CLAUDE_APART_PROFILE=work claude -p x' 'export CLAUDE_APART_PROFILE=work' \
    'env CLAUDE_APART_PROFILE="work" CLAUDE_CONFIG_DIR="${HOME}/.claude-work" claude -p x' || return 1
  _allows personal 'CLAUDE_APART_PROFILE=personal claude -p x' || return 1
}

# ---- Herdr ----------------------------------------------------------------------

test_herdr_read_rules() {
  t_two_profiles
  _herdr_std
  _blocks work 'herdr pane read w2:p1' || return 1
  _allows work 'herdr pane read w1:p4' || return 1
  _allows personal 'herdr pane read w1:p4' || return 1    # read grant
  _blocks work 'herdr agent read rev' 'herdr pane read -- w2:p1' || return 1
  _blocks work 'herdr pane wait-output w2:p1 --match x' 'herdr agent wait rev --until idle' \
    'herdr agent explain rev' || return 1
  _allows work 'herdr agent read me --source recent-unwrapped --lines 120' \
    'herdr pane read w1:p4 --source recent --lines 50 --format text' || return 1
  _allows personal 'herdr agent wait rev' 'herdr agent explain w1:p1' || return 1
  if grep -v -e '^workspace get ' -e '^agent get ' "$T/herdr.calls"; then
    echo "the guard ran more than lookups"; return 1
  fi
}

test_herdr_input_rules() {
  t_two_profiles
  _herdr_std
  _blocks personal 'herdr agent prompt w1:p1 "x"' || return 1
  _allows work 'herdr pane run w1:p2 ls' || return 1
  _blocks work 'herdr pane send-keys w2:p1 enter' || return 1
  _blocks personal 'herdr pane send-text w1:p1 hi' 'herdr agent start r2 --kind claude --pane w1:p2' \
    'herdr agent send-keys me esc' || return 1
  _allows work 'herdr agent start r2 --kind claude --pane w1:p2 -- --model x' \
    'herdr agent prompt me "go" --wait --timeout 120000' || return 1
  _allows personal 'herdr agent prompt rev hi --wait' || return 1
  _blocks work 'herdr agent start r2 --kind claude' 'bash -c "herdr pane run w2:p1 ls"' \
    'timeout 9 /opt/bin/herdr pane run w2:p1 ls' 'herdr pane run w1:p2 ls; herdr pane run w2:p1 ls' \
    'herdr pane run w1:p2 ls | herdr pane send-keys w2:p1 enter' || return 1
}

test_herdr_unknown_blocked() { # Review Focus 5
  t_two_profiles
  _herdr_std
  _blocks work 'herdr pane read w3:p1' || return 1
  _blocks work 'herdr --machine m pane read w1:p1' || return 1
  _blocks work 'herdr --machine=m pane read w1:p1' 'herdr --session t pane read w1:p1' \
    'herdr --remote h pane read w1:p1' 'herdr pane read w9:p1' 'herdr agent read ghost' \
    'herdr pane read' 'herdr pane read "$(echo w1:p1)"' 'herdr pane read $P' \
    'herdr pane read w1:p1 --frobnicate' 'xargs herdr pane read' 'herdr workspace close w1:p1' \
    'herdr tab close w1' 'herdr pane read w1:t1' 'h=herdr; $h pane read w1:p1' || return 1
  _herdr_script 'exit 1'
  _blocks work 'herdr pane read w1:p1' || return 1
  _herdr_script 'echo "not json"'
  _blocks work 'herdr pane read w1:p1' || return 1
  _herdr_script 'echo "{\"result\":{\"agent\":{\"pane_id\":\"rev\"}}}"'
  _blocks work 'herdr agent read rev' || return 1
  rm -f "$T/bin/herdr"
  _blocks work 'herdr pane read w1:p1' || return 1    # herdr not there
}

test_herdr_env_changes_blocked() { # lookups use this process's Herdr env; a command may not change it
  t_two_profiles
  _herdr_std
  _blocks work 'HERDR_SOCKET=/tmp/s herdr pane read w1:p1' 'unset HERDR_SOCKET; herdr pane read w1:p1' \
    'export HERDR_PANE_ID=w1:p1; herdr pane read --current' 'env -u HERDR_SOCKET herdr pane run w1:p2 ls' || return 1
  _blocks work 'HERDR_SOCKET=/tmp/s herdr pane list' || return 1    # R46: any herdr call
}

test_herdr_listing_allowed() {
  t_two_profiles
  _herdr_std
  _allows work 'herdr workspace list' 'herdr pane list' 'herdr agent list' 'herdr tab list --workspace w2' \
    'herdr pane split --current --direction right --no-focus' 'herdr --help' 'herdr pane' || return 1
  [ ! -e "$T/herdr.calls" ] || { echo "listing needs no lookup"; return 1; }
}

test_herdr_current_target() { # --current and $HERDR_PANE_ID are the caller's own pane
  t_two_profiles
  _herdr_std
  HERDR_PANE_ID=w1:p3 _allows work 'herdr pane read --current' 'herdr pane read "$HERDR_PANE_ID"' \
    'herdr pane run ${HERDR_PANE_ID} ls' || return 1
  HERDR_PANE_ID=w2:p1 _blocks work 'herdr pane read --current' 'herdr pane read "$HERDR_PANE_ID"' || return 1
  _blocks work 'herdr pane read --current' 'herdr pane read "$HERDR_PANE_ID"' || return 1    # not set
  _allows work 'herdr pane read --pane w1:p3' || return 1
  _blocks work 'herdr pane read --pane=w2:p1' 'herdr pane read w1:p1 --pane w2:p1' || return 1
}

test_herdr_rename_close_are_input() {
  t_two_profiles
  _herdr_std
  _blocks work 'herdr workspace rename w2 x' 'herdr workspace close w2' 'herdr tab rename w2:t1 x' \
    'herdr tab close w2:t1' 'herdr pane close w2:p1' || return 1
  _allows work 'herdr workspace rename w1 "🟧 WORK · y"' 'herdr tab close w1:t2' 'herdr pane close w1:p9' \
    'herdr workspace close w1 --group' || return 1
  _blocks personal 'herdr workspace close w1' 'herdr tab rename w1:t1 x' || return 1    # a read grant is no input
}

test_herdr_relabel_and_move() { # a pane may not change profile by a new label, a move or a swap
  t_two_profiles
  _herdr_std
  _blocks personal 'herdr workspace rename w2 "🟧 WORK · x"' \
    'herdr workspace rename w2 "$LABEL"' 'herdr pane move w2:p1 --new-workspace --label "$(cat l)"' \
    'herdr pane move w2:p1 --new-workspace --label "🟧 WORK · x"' || return 1
  _allows personal 'herdr workspace rename w2 "🟪 PERS · y"' \
    'herdr pane move w2:p1 --new-workspace --label "🟪 PERS · z"' || return 1
  _blocks personal 'herdr workspace rename w2 plain' 'herdr pane move w2:p1 --new-workspace --label x' || return 1    # R45
  _blocks work 'herdr pane move w1:p1 --tab w2:t1 --split right' 'herdr pane move w2:p1 --new-tab' \
    'herdr pane swap --source-pane w1:p1 --target-pane w2:p1' 'herdr agent attach rev' \
    'herdr agent rename rev x' 'herdr pane rename w2:p1 x' || return 1
  _allows work 'herdr pane move w1:p1 --new-tab --workspace w1 --no-focus' || return 1
}

test_herdr_label_must_be_own() { # R45: every workspace label herdr writes starts with the own <emoji> <TAG>
  t_two_profiles
  _herdr_std
  _blocks personal 'herdr workspace rename w2 notes && herdr pane run w2:p2 "claude -p hi"' \
    'herdr workspace rename w2 notes' 'herdr workspace rename w2 🟪 PERS · x' \
    'herdr workspace rename w2 "🟪 PERS · x" extra' 'herdr workspace rename w2' 'herdr workspace create' \
    'herdr workspace create --label notes --cwd /tmp' 'herdr workspace create --label "$L"' \
    'herdr workspace create --label "🟧 WORK · x"' 'herdr worktree create --branch b' \
    'herdr worktree create --branch b --label notes' 'herdr worktree open --path /tmp/wt --label "🟧 WORK · wt"' \
    'herdr pane move w2:p1 --new-workspace' || return 1
  _allows personal 'herdr workspace create --label "🟪 PERS · x" --cwd /tmp --no-focus' \
    'herdr worktree create --branch b --label "🟪 PERS · b"' 'herdr worktree open --path /tmp/wt --label "🟪 PERS"' \
    'herdr tab create --label notes' 'herdr pane move w2:p1 --new-tab --label notes' || return 1
  _blocks work 'herdr workspace create --label "🟪 PERS · x"' || return 1
}

test_herdr_env_option_blocked() { # R46: --env HERDR_* (or an unknown --env) on any herdr call
  t_two_profiles
  _herdr_std
  _blocks work 'herdr pane split --current --direction right --env HERDR_WORKSPACE_ID=w1' \
    'herdr tab create --env=HERDR_PANE_ID=w1:p1' 'herdr workspace create --label "🟧 WORK · x" --env "$E"' \
    'unset HERDR_SOCKET; herdr workspace list' || return 1
  _allows work 'herdr workspace create --label "🟧 WORK · x" --env FOO=1' 'echo "$HERDR_PANE_ID"' || return 1
}

test_herdr_indirect_calls_blocked() { # R47
  t_two_profiles
  _herdr_std
  _blocks work '$(command -v herdr) pane read w2:p1' 'H=$(command -v herdr); $H pane read w2:p1' \
    'CMD="pane read w2:p1"; herdr $CMD' 'echo pane read w2:p1 | xargs herdr' \
    'f() { herdr "$@"; }; f pane read w2:p1' '${HB:-herdr} pane read w2:p1' 'herdr pane "$V" w2:p1' \
    '"$(which herdr)" agent prompt me hi' '`which herdr` pane run w1:p2 ls' \
    'find . -name x -exec herdr {} \;' 'herdr terminal session $X w1:p1' || return 1
  _allows work 'which herdr' 'command -v herdr' 'command -V herdr' 'type herdr' 'type -a herdr' \
    'ls -l "$(command -v herdr)"' || return 1
}

test_trailing_word_rule() { # R49: a last claude-apart/herdr word blocks only under xargs/parallel; after find -exec always
  t_two_profiles
  _herdr_std
  _allows work 'cat bin/claude-apart' 'bash -n bin/claude-apart' 'git add bin/claude-apart' \
    'ls ~/.config/herdr' 'command -v herdr' 'herdr' 'claude-apart' 'echo x | grep herdr' \
    'echo x | xargs which herdr' 'xargs command -v claude-apart < f' 'cat x | xargs -n1 echo herdr x' || return 1
  _blocks work 'echo pane read w2:p1 | xargs herdr' 'xargs claude-apart < f' 'parallel herdr' \
    'echo a | /usr/bin/xargs -0 herdr' 'X=1 xargs claude-apart' 'parallel -j2 claude-apart' \
    'claude-apart copy personal work' 'bash bin/claude-apart copy personal work' || return 1
  # find -exec: from a folder that holds no profile, so only R49 can block
  local d="$T/proj" c
  mkdir -p "$d"
  for c in 'find . -name x -exec cat {} \;' 'find . -exec ls ~/.config/herdr \;'; do
    _run_bash work "$c" "$d"; _expect_allow "work in proj: $c" || return 1
  done
  for c in 'find . -name x -exec herdr {} \;' 'find . -execdir claude-apart {} \;' 'find . -ok herdr --help \;' \
    'find . -okdir claude-apart status \;' 'find . -exec /opt/bin/herdr \;' 'find . -exec claude-apart \;'; do
    _run_bash work "$c" "$d"; _expect_block "work in proj: $c" || return 1
  done
}

test_herdr_terminal_and_other_groups() {
  t_two_profiles
  _herdr_std
  _blocks work 'herdr terminal session observe w2:p1' 'herdr terminal attach t5' \
    'herdr terminal session observe rev' 'herdr terminal session control w1:p1 --frobnicate' || return 1
  _allows work 'herdr terminal session observe w1:p1 --cols 80 --rows 24' \
    'herdr terminal session control w1:p1 --takeover' 'herdr terminal title set x' || return 1
  _allows personal 'herdr terminal session observe w1:p1' || return 1    # read grant
  _blocks personal 'herdr terminal session control w1:p1' 'herdr terminal attach w1:p1' || return 1
  _blocks work 'herdr server stop' 'herdr session stop main' 'herdr session delete main' \
    'herdr session attach main' 'herdr integration install claude' 'herdr integration uninstall claude' \
    'herdr api snapshot' 'herdr worktree remove --workspace w2' || return 1
  _allows work 'herdr session list' 'herdr api schema --json' 'herdr worktree list' 'herdr integration status' \
    'herdr worktree remove --workspace w1 --force' 'herdr notification show done --sound done' || return 1
}

test_launcher_name_from_variable() { # claude-<rest> where the rest cannot be known
  t_two_profiles
  _blocks work 'for p in personal; do claude-$p -p x; done' 'claude-${P} -p x' 'claude-`echo personal` -p x' \
    '"claude-$(echo personal)" -p x' 'claude-{personal,x} -p x' || return 1
  _allows work 'ls ~/.local/share/claude-apart/bin/claude-*' 'claude-work -p x' || return 1
}

test_agent_explain_file_is_other() { # explain --file reads a file, not a pane
  t_two_profiles
  _herdr_std
  _allows work 'herdr agent explain --file /tmp/d.txt --agent claude --json' || return 1
  _blocks work 'herdr agent explain rev --file /tmp/d.txt' || return 1
}

# ---- timeouts -------------------------------------------------------------------

test_herdr_timeout_blocks_in_time() { # a hung herdr is killed after 3 s; that lookup failed: block
  t_two_profiles
  _herdr_script 'echo $$ >> "$T/herdr.pids"; exec sleep 30'
  local t0 ms
  t0=$(_now_ms)
  _run_bash work 'herdr agent read me'
  ms=$(( $(_now_ms) - t0 ))
  _expect_block "hung herdr, inside the 5 s budget" || return 1
  [ "$ms" -ge 2500 ] && [ "$ms" -lt 4500 ] || { echo "took $ms ms (want about 3 s)"; return 1; }
  [ -s "$T/herdr.pids" ] || { echo "the stub never ran"; return 1; }
  _all_gone "$T/herdr.pids" || return 1
}

test_hook_timeout_kills_herdr_group() { # R41: past the budget the supervisor kills herdr and its children too
  t_two_profiles
  _herdr_script 'sleep 30 & echo "$$ $!" >> "$T/herdr.pids"; wait'
  local t0 ms
  t0=$(_now_ms)
  CLAUDE_APART_HOOK_BUDGET=0.5 _run_bash work 'herdr pane read w1:p1'
  ms=$(( $(_now_ms) - t0 ))
  _expect_guard_error "budget 0.5 s, herdr deadline 3 s" || return 1
  [ "$ms" -lt 2500 ] || { echo "took $ms ms"; return 1; }
  [ -s "$T/herdr.pids" ] || { echo "the stub never ran"; return 1; }
  _all_gone "$T/herdr.pids" || return 1
}

test_no_alarm_in_guard_modules() { # R27/R41: the supervisor's alarm is the only one in hook processes
  local hits
  hits=$(cat "$REPO"/lib/ClaudeApart/*.pm | grep -v '^[[:space:]]*#' | grep -c 'alarm')
  assert_eq 0 "$hits" "alarm in lib/ClaudeApart" || return 1
}
