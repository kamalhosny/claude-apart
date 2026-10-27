# Tests for installing the guard, hooks and status line into profile settings.
# Everything happens under $T: the settings files are <profile dir>/settings.json.

CAPART="$REPO/libexec/claude-apart/capart.pl"

_install() { run perl -I"$REPO/lib" "$CAPART" settings install --profile "$1"; }
_uninstall() { run perl -I"$REPO/lib" "$CAPART" settings uninstall --profile "$1"; }

# Prints a JSON value from a settings file as text: _jq <file> <perl expr on $d>.
_jq() {
  perl -MJSON::PP -e 'local $/; open my $f, "<", $ARGV[0] or die; my $d = JSON::PP->new->utf8->decode(<$f>); my $v = eval $ARGV[1]; die $@ if $@; print JSON::PP->new->canonical->allow_nonref->encode($v), "\n"' "$1" "$2"
}

_deep_equal() { # <file a> <file b>
  perl -MJSON::PP -e 'sub rd { local $/; open my $f, "<", $_[0] or die; JSON::PP->new->utf8->canonical->encode(JSON::PP->new->utf8->decode(<$f>)) } exit(rd($ARGV[0]) eq rd($ARGV[1]) ? 0 : 1)' "$1" "$2"
}

test_install_adds_rules_hooks_statusline() {
  t_two_profiles
  _install work; assert_rc 0 "install work" || return 1
  local w="$HOME/.claude-work/settings.json" deny
  deny=$(_jq "$w" '$d->{permissions}{deny}')
  assert_contains "$deny" "Read(/$HOME/.claude/**)" "read dir rule" || return 1
  assert_contains "$deny" "Read(/$HOME/.claude)" "read bare rule" || return 1
  assert_contains "$deny" "Read(/$HOME/.claude.json)" "identity file rule" || return 1
  assert_contains "$deny" "Edit(/$HOME/.claude/**)" "edit dir rule" || return 1
  assert_not_contains "$deny" "Read(/$HOME/.claude.json/**)" "no /** on a file" || return 1
  local ev
  for ev in PreToolUse UserPromptSubmit SessionStart; do
    assert_contains "$(_jq "$w" "\$d->{hooks}{$ev}")" "--profile 'work'" "hook $ev" || return 1
  done
  assert_contains "$(_jq "$w" '$d->{statusLine}{command}')" "statusline --profile 'work'" "statusline" || return 1
  _install personal; assert_rc 0 "install personal" || return 1
  deny=$(_jq "$HOME/.claude/settings.json" '$d->{permissions}{deny}')
  assert_not_contains "$deny" "Read(/$HOME/.claude-work/**)" "personal can read work" || return 1
  assert_contains "$deny" "Edit(/$HOME/.claude-work/**)" "personal may not edit work" || return 1
}

test_hook_command_shape() { # R13
  t_two_profiles
  _install work || true
  local w="$HOME/.claude-work/settings.json" c
  c=$(_jq "$w" '$d->{hooks}{PreToolUse}[0]{hooks}[0]{command}')
  assert_contains "$c" "'/usr/bin/perl' '-I$REPO/lib' '$REPO/libexec/claude-apart/capart.pl' hook pre-tool --profile 'work' || exit 2" "pre-tool" || return 1
  c=$(_jq "$w" '$d->{hooks}{UserPromptSubmit}[0]{hooks}[0]{command}')
  assert_contains "$c" "hook prompt --profile 'work' || exit 2" "prompt" || return 1
  c=$(_jq "$w" '$d->{hooks}{SessionStart}[0]{hooks}[0]{command}')
  assert_contains "$c" "hook session-start --profile 'work'\"" "session-start has no suffix" || return 1
  assert_not_contains "$c" "exit 2" "session-start has no suffix" || return 1
  assert_eq 10 "$(_jq "$w" '$d->{hooks}{PreToolUse}[0]{hooks}[0]{timeout}')" "timeout" || return 1
  assert_eq '"*"' "$(_jq "$w" '$d->{hooks}{PreToolUse}[0]{matcher}')" "matcher" || return 1
  c=$(_jq "$w" '$d->{statusLine}{command}')
  assert_not_contains "$c" "exit 2" "statusline has no suffix" || return 1
  # a perl found first on PATH is the one written
  mkdir -p "$T/pbin"; ln -s /usr/bin/perl "$T/pbin/perl"
  PATH="$T/pbin:$PATH" _install work
  c=$(_jq "$w" '$d->{hooks}{PreToolUse}[0]{hooks}[0]{command}')
  assert_contains "$c" "'$T/pbin/perl' '-I" "perl from PATH" || return 1
}

test_family_rules() {
  t_two_profiles
  _install work
  local deny
  deny=$(_jq "$HOME/.claude-work/settings.json" '$d->{permissions}{deny}')
  assert_contains "$deny" "Read(/$HOME/.claude.json.*)" "family glob" || return 1
  assert_contains "$deny" "Edit(/$HOME/.claude.json)" "family bare edit" || return 1
}

test_install_is_idempotent() {
  t_two_profiles
  _install work; _install work
  cp "$HOME/.claude-work/settings.json" "$T/once"
  cp "$HOME/.claude-work/.claude-apart-state.json" "$T/once.state"
  _install work; assert_rc 0 "third install" || return 1
  cmp "$T/once" "$HOME/.claude-work/settings.json" || { echo "settings changed"; return 1; }
  cmp "$T/once.state" "$HOME/.claude-work/.claude-apart-state.json" || { echo "state changed"; return 1; }
  # a fresh install and a repeated one give the same bytes
  rm -f "$HOME/.claude-work/settings.json" "$HOME/.claude-work/.claude-apart-state.json"
  _install work
  cmp "$T/once" "$HOME/.claude-work/settings.json" || { echo "fresh differs"; return 1; }
}

test_existing_settings_preserved_and_restored() {
  t_two_profiles
  local w="$HOME/.claude-work/settings.json"
  cat > "$w" <<'JSON'
{"model":"x","permissions":{"deny":["Bash(rm *)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"my-hook"}]}]},"statusLine":{"type":"command","command":"my-status"},"theme":"light"}
JSON
  cp "$w" "$T/seed.json"
  perl -I"$REPO/lib" "$CAPART" config set-profile work theme dark
  _install work; assert_rc 0 "install" || return 1
  assert_contains "$(_jq "$w" '$d->{permissions}{deny}')" "Bash(rm *)" "kept deny" || return 1
  assert_contains "$(_jq "$w" '$d->{hooks}{SessionStart}')" "my-hook" "kept hook" || return 1
  assert_contains "$(_jq "$w" '$d->{hooks}{SessionStart}')" "--profile 'work'" "added hook" || return 1
  assert_contains "$(_jq "$w" '$d->{statusLine}{command}')" "--chain 'my-status'" "chained" || return 1
  assert_eq '"dark"' "$(_jq "$w" '$d->{theme}')" "theme" || return 1
  assert_eq '"x"' "$(_jq "$w" '$d->{model}')" "model" || return 1
  _install work   # twice: still restores to the seed
  _uninstall work; assert_rc 0 "uninstall" || return 1
  _deep_equal "$w" "$T/seed.json" || { echo "not restored:"; cat "$w"; return 1; }
  [ ! -e "$HOME/.claude-work/.claude-apart-state.json" ] || { echo "state file left"; return 1; }
}

test_uninstall_from_empty_restores_empty_object() {
  t_two_profiles
  perl -I"$REPO/lib" "$CAPART" config set-profile work theme dark
  _install work
  _uninstall work
  assert_eq "{}" "$(_jq "$HOME/.claude-work/settings.json" '$d')" "back to {}" || return 1
}

test_uninstall_without_state_is_noop() {
  t_two_profiles
  echo '{"model":"x"}' > "$HOME/.claude-work/settings.json"
  cp "$HOME/.claude-work/settings.json" "$T/before"
  _uninstall work; assert_rc 0 "no state" || return 1
  cmp "$T/before" "$HOME/.claude-work/settings.json" || return 1
  _uninstall personal; assert_rc 0 "no state, no settings" || return 1
  [ ! -e "$HOME/.claude/settings.json" ] || { echo "created a file"; return 1; }
}

test_existing_claude_apart_statusline_not_chained() {
  t_two_profiles
  _install work
  # state lost, our status line still in the file
  rm -f "$HOME/.claude-work/.claude-apart-state.json"
  _install work
  assert_not_contains "$(_jq "$HOME/.claude-work/settings.json" '$d->{statusLine}{command}')" "--chain" "no self chain" || return 1
}

test_user_changes_survive_uninstall() {
  t_two_profiles
  _install work
  local w="$HOME/.claude-work/settings.json"
  perl -MJSON::PP -e 'local $/; open my $f,"<",$ARGV[0]; my $d=decode_json(<$f>); push @{$d->{permissions}{deny}}, "Bash(sudo *)"; $d->{statusLine}{command}="mine"; open my $o,">",$ARGV[0]; print $o JSON::PP->new->utf8->encode($d)' "$w"
  _uninstall work; assert_rc 0 "uninstall" || return 1
  assert_eq '["Bash(sudo *)"]' "$(_jq "$w" '$d->{permissions}{deny}')" "own rule kept, ours gone" || return 1
  assert_eq '"mine"' "$(_jq "$w" '$d->{statusLine}{command}')" "edited status line left alone" || return 1
  assert_eq null "$(_jq "$w" '$d->{hooks}')" "hooks removed" || return 1
}

test_backup_written_once() {
  t_two_profiles
  local w="$HOME/.claude-work/settings.json"
  echo '{"model":"x"}' > "$w"
  _install work
  assert_eq '{"model":"x"}' "$(cat "$w.claude-apart.bak")" "backup is the original" || return 1
  echo '{"model":"changed"}' > "$w"
  _install work
  assert_eq '{"model":"x"}' "$(cat "$w.claude-apart.bak")" "backup not overwritten" || return 1
}

test_corrupt_settings_refused() {
  t_two_profiles
  local w="$HOME/.claude-work/settings.json"
  printf '{"model": ' > "$w"
  cp "$w" "$T/corrupt"
  _install work
  [ "$RC" -ne 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$ERR" "settings.json" "message names the file" || return 1
  cmp "$T/corrupt" "$w" || { echo "file was touched"; return 1; }
  [ ! -e "$w.claude-apart.bak" ] || { echo "backup of corrupt file"; return 1; }
  [ ! -e "$HOME/.claude-work/.claude-apart-state.json" ] || { echo "state written"; return 1; }
  echo '[1]' > "$w"
  _install work
  [ "$RC" -ne 0 ] || { echo "expected failure on array"; return 1; }
  assert_eq '[1]' "$(cat "$w")" "array untouched" || return 1
  _uninstall work   # no state: still a no-op
  assert_rc 0 "uninstall no state" || return 1
}

test_symlinked_root_gets_both_spellings() { # R19
  t_two_profiles
  mv "$HOME/.claude-work" "$HOME/real-work"
  ln -s "$HOME/real-work" "$HOME/.claude-work"
  _install personal; assert_rc 0 "install" || return 1
  local deny; deny=$(_jq "$HOME/.claude/settings.json" '$d->{permissions}{deny}')
  assert_contains "$deny" "Edit(/$HOME/.claude-work/**)" "literal spelling" || return 1
  assert_contains "$deny" "Edit(/$HOME/real-work/**)" "canonical spelling" || return 1
}

test_state_file_records_original() {
  t_two_profiles
  local w="$HOME/.claude-work/settings.json"
  echo '{"statusLine":{"type":"command","command":"my-status"}}' > "$w"
  _install work
  local s="$HOME/.claude-work/.claude-apart-state.json"
  assert_eq '"my-status"' "$(_jq "$s" '$d->{statusLine_original}{command}')" "original status line" || return 1
  assert_contains "$(_jq "$s" '$d->{deny}')" "Read(/$HOME/.claude/**)" "deny listed" || return 1
}

test_sync_all_profiles() {
  t_two_profiles
  run claude-apart sync; assert_rc 0 "sync" || return 1
  assert_contains "$OUT" "work: installed" "work line" || return 1
  assert_contains "$OUT" "personal: installed" "personal line" || return 1
  assert_contains "$(cat "$HOME/.claude-work/settings.json")" "--profile 'work'" "work file" || return 1
  assert_contains "$(cat "$HOME/.claude/settings.json")" "--profile 'personal'" "personal file" || return 1
}

test_sync_continues_after_failure() {
  t_two_profiles
  printf 'broken' > "$HOME/.claude/settings.json"
  run claude-apart sync
  [ "$RC" -ne 0 ] || { echo "expected non-zero"; return 1; }
  assert_contains "$OUT" "personal: failed" "failed line" || return 1
  assert_contains "$OUT" "work: installed" "other profile still done" || return 1
}

test_sync_refused_inside_session() {
  t_two_profiles
  CLAUDE_CODE_CHILD_SESSION=1 run claude-apart sync
  assert_rc 1 "refused" || return 1
  [ ! -e "$HOME/.claude-work/settings.json" ] || { echo "wrote anyway"; return 1; }
}
