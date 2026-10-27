# Tests for `claude-apart copy` (item-by-item copy between profiles).

_copy_fixture() {
  t_two_profiles
  local p=$HOME/.claude
  mkdir -p "$p/projects/-x/memory" "$p/skills/review" "$p/hooks" "$p/agents"
  printf -- '---\nname: work note\ndescription: about the job\n---\nbody a\n' > "$p/projects/-x/memory/a.md"
  printf -- '---\nname: private note\ndescription: not for work\n---\nbody b\n' > "$p/projects/-x/memory/b.md"
  printf -- '- [work note](a.md) — about the job\n- [private note](b.md) — not for work\n' > "$p/projects/-x/memory/MEMORY.md"
  printf 'SKILL\n' > "$p/skills/review/SKILL.md"
  printf '{"x":1}\n' > "$p/projects/-x/abc.jsonl"
  printf 'echo hi\n' > "$p/hooks/h.sh"; chmod +x "$p/hooks/h.sh"
  printf '{"model":"opus","hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"~/.claude/hooks/h.sh"}]}]}}\n' > "$p/settings.json"
  printf 'hello\n' > "$p/history.jsonl"
  printf '{"c":1}\n' > "$p/.credentials.json"
}

# answers: one line each, from a file the helper reads as the terminal
_copy_run() { # <answers> [from to]
  printf '%b' "$1" > "$T/answers"
  CLAUDE_APART_TTY="$T/answers" run claude-apart copy "${2:-personal}" "${3:-work}"
}

_apply() { run capart_pl copy-apply "$@"; }
capart_pl() { perl -I"$REPO/lib" "$REPO/libexec/claude-apart/capart.pl" "$@"; }

test_items_exclude_history() {
  _copy_fixture
  run capart_pl copy-items personal work
  assert_rc 0 "items" || return 1
  assert_contains "$OUT" "projects/-x/memory/a.md" "a" || return 1
  assert_contains "$OUT" "projects/-x/memory/b.md" "b" || return 1
  assert_contains "$OUT" "skills/review" "skill" || return 1
  assert_contains "$OUT" "PostToolUse#0" "hook" || return 1
  assert_contains "$OUT" "model" "model setting" || return 1
  assert_not_contains "$OUT" "abc.jsonl" "transcript" || return 1
  assert_not_contains "$OUT" "history" "history" || return 1
  assert_not_contains "$OUT" "credentials" "credentials" || return 1
  assert_not_contains "$OUT" "MEMORY.md" "index is not an item" || return 1
}

test_items_never_show_email() {
  _copy_fixture
  run capart_pl copy-items personal work
  assert_not_contains "$OUT" "example.com" "no email" || return 1
}

test_copy_one_memory_updates_index() {
  _copy_fixture
  _copy_yes_only "projects/-x/memory/a.md" || return 1
  [ -f "$HOME/.claude-work/projects/-x/memory/a.md" ] || { echo "a.md missing"; return 1; }
  [ ! -e "$HOME/.claude-work/projects/-x/memory/b.md" ] || { echo "b.md copied"; return 1; }
  local idx; idx=$(cat "$HOME/.claude-work/projects/-x/memory/MEMORY.md")
  assert_contains "$idx" "(a.md)" "a line" || return 1
  assert_not_contains "$idx" "(b.md)" "no b line" || return 1
}

# Builds an answers file with y only for the item whose id is $1, then runs copy.
_copy_yes_only() {
  local id=$1 ans="" k i label n=0
  while IFS=$'\t' read -r k i label; do
    [ -n "$k" ] || continue
    if [ "$i" = "$id" ]; then ans="${ans}y\n"; else ans="${ans}n\n"; fi
  done <<EOF2
$(capart_pl copy-items personal work)
EOF2
  _copy_run "$ans"
  assert_rc 0 "copy" || return 1
}

test_memory_without_index_line_gets_generated_one() {
  _copy_fixture
  printf -- '- [other](zzz.md) — other\n' > "$HOME/.claude/projects/-x/memory/MEMORY.md"
  _apply personal work memory projects/-x/memory/a.md
  assert_rc 0 "apply" || return 1
  assert_contains "$(cat "$HOME/.claude-work/projects/-x/memory/MEMORY.md")" "- [work note](a.md) — about the job" "generated line" || return 1
}

test_memory_index_line_not_duplicated() {
  _copy_fixture
  _apply personal work memory projects/-x/memory/a.md || true
  _apply personal work memory projects/-x/memory/a.md
  assert_rc 0 "again" || return 1
  local n; n=$(grep -c '(a.md)' "$HOME/.claude-work/projects/-x/memory/MEMORY.md")
  assert_eq 1 "$n" "one line" || return 1
}

test_hook_path_rewritten() {
  _copy_fixture
  _apply personal work hook PostToolUse#0
  assert_rc 0 "apply" || return 1
  local s; s=$(cat "$HOME/.claude-work/settings.json")
  assert_contains "$s" "~/.claude-work/hooks/h.sh" "rewritten" || return 1
  assert_not_contains "$s" "~/.claude/hooks" "old path gone" || return 1
  [ -x "$HOME/.claude-work/hooks/h.sh" ] || { echo "script not copied"; return 1; }
}

test_hook_absolute_path_rewritten() {
  _copy_fixture
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/.claude/hooks/h.sh --x"}]}]}}\n' "$HOME" > "$HOME/.claude/settings.json"
  _apply personal work hook Stop#0
  assert_rc 0 "apply" || return 1
  assert_contains "$(cat "$HOME/.claude-work/settings.json")" "$HOME/.claude-work/hooks/h.sh --x" "abs rewritten" || return 1
}

test_copy_refused_in_session() {
  _copy_fixture
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart copy personal work
  [ "$RC" != 0 ] || { echo "ran in session"; return 1; }
  CLAUDE_CODE_CHILD_SESSION=1 run capart_pl copy-items personal work
  assert_rc 1 "items in session" || return 1
  CLAUDE_CODE_CHILD_SESSION=1 run capart_pl copy-apply personal work memory projects/-x/memory/a.md
  assert_rc 1 "apply in session" || return 1
  [ ! -e "$HOME/.claude-work/projects" ] || { echo "wrote"; return 1; }
}

test_no_bulk_from_stdin() {
  _copy_fixture
  CLAUDE_APART_TTY=/dev/null run bash -c 'yes | claude-apart copy personal work'
  [ ! -e "$HOME/.claude-work/projects" ] || { echo "copied from stdin"; return 1; }
  [ ! -e "$HOME/.claude-work/skills" ] || { echo "copied from stdin"; return 1; }
  assert_contains "$OUT" "skipped" "report" || return 1
}

test_no_tty_refuses() {
  _copy_fixture
  CLAUDE_APART_TTY="$T/nothing-here" run claude-apart copy personal work
  [ "$RC" != 0 ] || { echo "ran without tty"; return 1; }
  [ ! -e "$HOME/.claude-work/skills" ] || return 1
}

test_prompt_shows_visibility_line_and_limits_preview() {
  _copy_fixture
  perl -e 'print "line $_\n" for 1..30' > "$HOME/.claude/CLAUDE.md"
  _copy_run "n\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\n"
  assert_contains "$OUT" "this will be visible to work's account" "line" || return 1
  assert_contains "$OUT" "Copy? [y/N]" "prompt" || return 1
  assert_contains "$OUT" "line 8" "8th line" || return 1
  assert_not_contains "$OUT" "line 9" "only 8 lines" || return 1
  assert_not_contains "$OUT" "example.com" "no identity" || return 1
}

test_skill_dir_copied_whole() {
  _copy_fixture
  mkdir -p "$HOME/.claude/skills/review/sub"; echo y > "$HOME/.claude/skills/review/sub/f.txt"
  _apply personal work skill skills/review
  assert_rc 0 "apply" || return 1
  [ -f "$HOME/.claude-work/skills/review/sub/f.txt" ] || { echo missing; return 1; }
  [ -f "$HOME/.claude-work/skills/review/SKILL.md" ] || { echo missing; return 1; }
}

test_target_symlink_refused() {
  _copy_fixture
  mkdir -p "$T/outside"
  mkdir -p "$HOME/.claude-work/projects/-x"
  ln -s "$T/outside" "$HOME/.claude-work/projects/-x/memory"
  _apply personal work memory projects/-x/memory/a.md
  [ "$RC" != 0 ] || { echo "wrote through link"; return 1; }
  [ -z "$(ls "$T/outside")" ] || { echo "outside written"; return 1; }
  ln -s "$T/outside/victim" "$HOME/.claude-work/CLAUDE.md"
  echo mine > "$HOME/.claude/CLAUDE.md"
  _apply personal work claude-md CLAUDE.md
  [ "$RC" != 0 ] || { echo "wrote through file link"; return 1; }
  [ ! -e "$T/outside/victim" ] || { echo "victim written"; return 1; }
}

test_target_settings_symlink_refused() {
  _copy_fixture
  echo '{}' > "$T/real.json"
  ln -s "$T/real.json" "$HOME/.claude-work/settings.json"
  _apply personal work hook PostToolUse#0
  [ "$RC" != 0 ] || { echo "wrote settings link"; return 1; }
  assert_eq '{}' "$(cat "$T/real.json")" "real untouched" || return 1
}

test_dotdot_id_refused() {
  _copy_fixture
  echo secret > "$HOME/.claude/secret.md"
  _apply personal work memory "projects/-x/memory/../../../secret.md"
  [ "$RC" != 0 ] || { echo "accepted .."; return 1; }
  _apply personal work skill "skills/../.credentials.json"
  [ "$RC" != 0 ] || { echo "accepted .. 2"; return 1; }
  _apply personal work skill "/etc/passwd"
  [ "$RC" != 0 ] || { echo "accepted abs"; return 1; }
  [ ! -e "$HOME/.claude-work/secret.md" ] || return 1
  [ ! -e "$HOME/.claude-work/.credentials.json" ] || return 1
}

test_unlisted_items_refused() {
  _copy_fixture
  _apply personal work claude-md history.jsonl
  [ "$RC" != 0 ] || return 1
  _apply personal work skill projects/-x/abc.jsonl
  [ "$RC" != 0 ] || return 1
  [ ! -e "$HOME/.claude-work/history.jsonl" ] || return 1
}

test_source_symlink_outside_skipped() {
  _copy_fixture
  mkdir -p "$T/elsewhere/ev"; echo e > "$T/elsewhere/ev/SKILL.md"
  ln -s "$T/elsewhere/ev" "$HOME/.claude/skills/evil"
  echo inner > "$HOME/.claude/skills/review/real.txt"
  ln -s "$T/elsewhere/ev/SKILL.md" "$HOME/.claude/skills/review/out.txt"
  run capart_pl copy-items personal work
  assert_not_contains "$OUT" "skills/evil" "outside link not listed" || return 1
  _apply personal work skill skills/review
  assert_rc 0 "apply" || return 1
  [ ! -e "$HOME/.claude-work/skills/review/out.txt" ] || { echo "outside link copied"; return 1; }
  [ -f "$HOME/.claude-work/skills/review/real.txt" ] || return 1
}

test_source_symlink_inside_copied_as_content() {
  _copy_fixture
  echo data > "$HOME/.claude/skills/review/real.txt"
  ln -s real.txt "$HOME/.claude/skills/review/alias.txt"
  _apply personal work skill skills/review
  assert_rc 0 "apply" || return 1
  [ -f "$HOME/.claude-work/skills/review/alias.txt" ] && [ ! -L "$HOME/.claude-work/skills/review/alias.txt" ] || { echo "link not turned into content"; return 1; }
  assert_eq data "$(cat "$HOME/.claude-work/skills/review/alias.txt")" "content" || return 1
}

test_own_hooks_not_listed_or_copied() {
  _copy_fixture
  run claude-apart sync
  assert_rc 0 "sync" || return 1
  run capart_pl copy-items personal work
  assert_not_contains "$OUT" "PreToolUse" "own pre-tool hook" || return 1
  assert_not_contains "$OUT" "UserPromptSubmit" "own prompt hook" || return 1
  assert_not_contains "$OUT" "SessionStart" "own session hook" || return 1
  assert_not_contains "$OUT" "statusline" "own statusline" || return 1
  assert_contains "$OUT" "PostToolUse#0" "user hook still listed" || return 1
  _apply personal work hook PreToolUse#0
  [ "$RC" != 0 ] || { echo "copied own hook"; return 1; }
}

test_target_own_entries_survive_hook_copy() {
  _copy_fixture
  run claude-apart sync
  assert_rc 0 "sync" || return 1
  local before_state; before_state=$(cat "$HOME/.claude-work/.claude-apart-state.json")
  _apply personal work hook PostToolUse#0
  assert_rc 0 "apply" || return 1
  assert_eq "$before_state" "$(cat "$HOME/.claude-work/.claude-apart-state.json")" "state untouched" || return 1
  local s; s=$(cat "$HOME/.claude-work/settings.json")
  assert_contains "$s" "hook pre-tool --profile 'work'" "own pre-tool kept" || return 1
  assert_contains "$s" "statusline --profile 'work'" "own statusline kept" || return 1
  assert_contains "$s" "~/.claude-work/hooks/h.sh" "copied hook" || return 1
  run claude-apart check
  assert_rc 0 "check still passes" || return 1
}

test_statusline_chained_when_target_has_badge() {
  _copy_fixture
  printf '{"statusLine":{"type":"command","command":"~/.claude/hooks/h.sh"}}\n' > "$HOME/.claude/settings.json"
  run claude-apart sync
  assert_rc 0 "sync" || return 1
  # the source now has our badge; the item offered is its original line
  run capart_pl copy-items personal work
  assert_contains "$OUT" "statusline" "listed" || return 1
  _apply personal work statusline statusLine
  assert_rc 0 "apply" || return 1
  local s; s=$(cat "$HOME/.claude-work/settings.json")
  assert_contains "$s" "statusline --profile 'work' --chain '~/.claude-work/hooks/h.sh'" "chained" || return 1
  assert_contains "$(cat "$HOME/.claude-work/.claude-apart-state.json")" "~/.claude-work/hooks/h.sh" "state original" || return 1
  run claude-apart sync
  assert_rc 0 "resync" || return 1
  assert_contains "$(cat "$HOME/.claude-work/settings.json")" "--chain '~/.claude-work/hooks/h.sh'" "still chained after sync" || return 1
  run claude-apart check
  assert_rc 0 "check after chain" || return 1
  assert_not_contains "$OUT" "✗" "no failure" || return 1
}

test_statusline_set_when_target_has_none() {
  _copy_fixture
  printf '{"statusLine":{"type":"command","command":"~/.claude/hooks/h.sh"}}\n' > "$HOME/.claude/settings.json"
  _apply personal work statusline statusLine
  assert_rc 0 "apply" || return 1
  assert_contains "$(cat "$HOME/.claude-work/settings.json")" '"command" : "~/.claude-work/hooks/h.sh"' "set" || return 1
  [ -x "$HOME/.claude-work/hooks/h.sh" ] || { echo "script missing"; return 1; }
}

test_settings_copied_keep_others() {
  _copy_fixture
  printf '{"model":"opus","theme":"dark","enabledPlugins":{"p@m":true}}\n' > "$HOME/.claude/settings.json"
  printf '{"model":"sonnet","enabledPlugins":{"q@m":true},"other":1}\n' > "$HOME/.claude-work/settings.json"
  _apply personal work setting model
  _apply personal work setting enabledPlugins
  assert_rc 0 "apply" || return 1
  local s; s=$(cat "$HOME/.claude-work/settings.json")
  assert_contains "$s" '"model" : "opus"' "model" || return 1
  assert_contains "$s" '"p@m" : true' "plugin added" || return 1
  assert_contains "$s" '"q@m" : true' "plugin kept" || return 1
  assert_contains "$s" '"other" : 1' "other kept" || return 1
}

test_theme_not_offered_when_target_theme_is_managed() {
  _copy_fixture
  printf '{"theme":"dark"}\n' > "$HOME/.claude/settings.json"
  perl -pi -e 's/^theme = .*\n//; s/^(\[profile work\])$/$1\ntheme = light/' "$XDG_CONFIG_HOME/claude-apart/config"
  run claude-apart sync
  run capart_pl copy-items personal work
  assert_not_contains "$OUT" "theme" "theme managed by claude-apart" || return 1
}

test_copy_report_counts() {
  _copy_fixture
  local n; n=$(capart_pl copy-items personal work | wc -l | tr -d " ")
  _copy_run "n\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\n"
  assert_contains "$OUT" "Copied 0, skipped $n." "counts" || return 1
}

test_answers_run_out_midway() {
  _copy_fixture
  local n; n=$(capart_pl copy-items personal work | wc -l | tr -d " ")
  _copy_run "y\n"
  assert_contains "$OUT" "Copied 1, skipped $((n - 1))." "rest count as no" || return 1
}

test_unknown_profile_and_same_profile() {
  _copy_fixture
  run capart_pl copy-items personal nobody
  assert_rc 1 "unknown" || return 1
  run capart_pl copy-items personal personal
  assert_rc 1 "same" || return 1
}

# ---- fix round 1 ----

_hook_settings() { # <command>: the source settings have one Stop hook
  perl -MJSON::PP -e 'print encode_json({hooks=>{Stop=>[{hooks=>[{type=>"command",command=>shift}]}]}})' "$1" > "$HOME/.claude/settings.json"
}

test_hook_naming_settings_json_is_skipped() {
  _copy_fixture
  echo '{"mine":1}' > "$HOME/.claude-work/settings.json"
  _hook_settings '~/.claude/hooks/h.sh ~/.claude/settings.json'
  run capart_pl copy-items personal work
  assert_not_contains "$OUT" $'hook\tStop#0' "not offered" || return 1
  assert_contains "$OUT" "names settings.json inside personal, which cannot be copied" "reason" || return 1
  _apply personal work hook Stop#0
  [ "$RC" != 0 ] || { echo "applied"; return 1; }
  assert_eq '{"mine":1}' "$(cat "$HOME/.claude-work/settings.json")" "settings untouched" || return 1
}

test_hook_naming_private_note_is_skipped() {
  _copy_fixture
  _hook_settings 'cat ~/.claude/projects/-x/memory/b.md'
  run capart_pl copy-items personal work
  assert_contains "$OUT" "names projects/-x/memory/b.md inside personal" "reason" || return 1
  _apply personal work hook Stop#0
  [ "$RC" != 0 ] || return 1
  [ ! -e "$HOME/.claude-work/projects" ] || { echo "carried"; return 1; }
}

test_hook_carried_file_is_shown() {
  _copy_fixture
  _hook_settings '~/.claude/hooks/h.sh'
  mkdir -p "$HOME/.claude-work/hooks"; echo old > "$HOME/.claude-work/hooks/h.sh"
  run capart_pl copy-items personal work
  assert_contains "$OUT" "carries hooks/h.sh" "carry line" || return 1
  assert_contains "$OUT" "(replaces what work already has)" "replace note" || return 1
  _apply personal work hook Stop#0
  assert_rc 0 "apply" || return 1
  assert_eq "echo hi" "$(cat "$HOME/.claude-work/hooks/h.sh")" "carried" || return 1
}

test_linked_source_folders_not_followed() {
  _copy_fixture
  mkdir -p "$T/out/skills/evil" "$T/out/hooks"
  echo e > "$T/out/skills/evil/SKILL.md"; echo 'echo out' > "$T/out/hooks/h.sh"
  rm -rf "$HOME/.claude/skills" "$HOME/.claude/hooks"
  ln -s "$T/out/skills" "$HOME/.claude/skills"; ln -s "$T/out/hooks" "$HOME/.claude/hooks"
  run capart_pl copy-items personal work
  assert_not_contains "$OUT" "skills/evil" "linked skills dir" || return 1
  _hook_settings '~/.claude/hooks/h.sh'
  _apply personal work hook Stop#0
  [ ! -e "$HOME/.claude-work/hooks/h.sh" ] || { echo "carried through link"; return 1; }
}

test_theme_managed_in_source_not_offered() {
  _copy_fixture
  printf '{"theme":"x"}\n' > "$HOME/.claude/settings.json"
  perl -pi -e 's/^(\[profile personal\])$/$1\ntheme = dark/' "$XDG_CONFIG_HOME/claude-apart/config"
  run claude-apart sync
  run capart_pl copy-items personal work
  assert_not_contains "$OUT" "theme" "source theme is managed" || return 1
}

test_utf8_names_printed_as_utf8() {
  _copy_fixture
  printf '{"enabledPlugins":{"café@m":true}}\n' > "$HOME/.claude/settings.json"
  run capart_pl copy-items personal work
  assert_contains "$OUT" "café@m" "utf8 name" || return 1
}
