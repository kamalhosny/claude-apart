# Tests for ClaudeApart::Config and the capart.pl config commands.

test_config_parses_two_profiles() {
  t_two_profiles
  run capart config profiles
  assert_rc 0 "profiles" || return 1
  assert_eq "personal
work" "$OUT" "profile names in file order" || return 1
  run capart config shell work
  assert_contains "$OUT" "CA_DIR='$HOME/.claude-work'" "work dir expanded" || return 1
  assert_contains "$OUT" "CA_ADOPTED=0" "work not adopted" || return 1
  run capart config shell personal
  assert_contains "$OUT" "CA_ADOPTED=1" "personal adopted" || return 1
  run capart config default
  assert_eq "work" "$OUT" "default profile" || return 1
}

test_config_rejects_duplicate_tag() {
  mkdir -p "$XDG_CONFIG_HOME/claude-apart"
  printf '[profile a]\ndir = ~/.a\ntag = WORK\n[profile b]\ndir = ~/.b\ntag = WORK\n' \
    > "$XDG_CONFIG_HOME/claude-apart/config"
  run capart config profiles
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$ERR" "duplicate tag" "duplicate tag message" || return 1
}

test_config_rejects_bad_input() {
  local f="$XDG_CONFIG_HOME/claude-apart/config"
  mkdir -p "$XDG_CONFIG_HOME/claude-apart"
  printf '[profile a]\ndir = ~/.a\ntag = A\nbogus = 1\n' > "$f"
  run capart config profiles
  [ "$RC" != 0 ] || return 1
  assert_contains "$ERR" "unknown key" "unknown key" || return 1
  printf '[profile a]\ndir = ~/.a\n' > "$f"
  run capart config profiles
  assert_contains "$ERR" "missing tag" "missing tag" || return 1
  printf '[profile a]\ntag = A\n' > "$f"
  run capart config profiles
  assert_contains "$ERR" "missing dir" "missing dir" || return 1
  printf '[profile a]\ndir = ~/.a\ntag = A\nemoji = X\n[profile b]\ndir = ~/.b\ntag = B\nemoji = X\n' > "$f"
  run capart config profiles
  assert_contains "$ERR" "duplicate emoji" "duplicate emoji" || return 1
  printf '[profile apart]\ndir = ~/.a\ntag = A\n' > "$f"
  run capart config profiles
  [ "$RC" != 0 ] || return 1
  printf '[profile Bad_Name]\ndir = ~/.a\ntag = A\n' > "$f"
  run capart config profiles
  [ "$RC" != 0 ] || return 1
  printf 'this is not valid\n' > "$f"
  run capart config profiles
  assert_contains "$ERR" "syntax error" "syntax error" || return 1
}

test_config_rejects_duplicate_key() { # F10: a repeated key would hide the first value
  t_two_profiles
  local f="$XDG_CONFIG_HOME/claude-apart/config"
  printf 'protect = ~/a\nprotect = ~/b\n' >> "$f"
  run capart config profiles
  [ "$RC" != 0 ] || { echo "expected failure"; return 1; }
  assert_contains "$ERR" "claude-apart: duplicate key 'protect' in [profile work] at line 18; put all values on one line." "duplicate key message" || return 1
  pre_tool work Read '{"file_path":"/etc/hosts"}'
  assert_rc 2 "guard fails closed" || return 1
  assert_contains "$ERR" "claude-apart: guard error — blocked to be safe." "guard error text" || return 1
  printf 'default = work\ndefault = personal\n' > "$T/top"
  cat "$f" >> "$T/top"; sed -i.bak '/^protect/d' "$T/top"; cp "$T/top" "$f"
  run capart config profiles
  [ "$RC" != 0 ] || { echo "top-level repeat accepted"; return 1; }
  assert_contains "$ERR" "duplicate key 'default'" "top-level repeat" || return 1
}

test_config_foreign_paths() {
  t_two_profiles
  local code='use ClaudeApart::Config; my $c=ClaudeApart::Config::load(ClaudeApart::Config::config_path());
    my ($r,$w)=ClaudeApart::Config::foreign_paths($c,$ARGV[0]); print "R:$_\n" for @$r; print "W:$_\n" for @$w;'
  run perl -I"$REPO/lib" -e "$code" work
  assert_rc 0 "foreign_paths work" || return 1
  local rd; rd=$(printf '%s\n' "$OUT" | grep '^R:')
  assert_contains "$rd" "R:$HOME/.claude"$'\n' "work reads personal dir denied" || return 1
  assert_contains "$rd" "R:$HOME/.claude.json" "identity file denied" || return 1
  assert_contains "$rd" "R:$HOME/.claude.json.*" "identity file family denied" || return 1
  assert_contains "$rd" "R:$XDG_CONFIG_HOME/claude-apart" "config dir denied" || return 1
  assert_not_contains "$rd" "$HOME/.claude-work" "own dir not denied" || return 1
  run perl -I"$REPO/lib" -e "$code" personal
  rd=$(printf '%s\n' "$OUT" | grep '^R:'); local wd; wd=$(printf '%s\n' "$OUT" | grep '^W:')
  assert_not_contains "$rd" "$HOME/.claude-work" "can_read lifts read deny" || return 1
  assert_contains "$wd" "W:$HOME/.claude-work" "but write still denied" || return 1
  assert_contains "$rd" "R:$XDG_CONFIG_HOME/claude-apart" "config dir still read-denied" || return 1
}

test_config_round_trip() {
  t_two_profiles
  run capart config set-profile work theme dark
  assert_rc 0 "set-profile" || return 1
  run capart config shell work
  assert_contains "$OUT" "CA_THEME='dark'" "theme saved" || return 1
  local first; first=$(head -n 1 "$XDG_CONFIG_HOME/claude-apart/config")
  assert_eq "# claude-apart config — edit freely, then run: claude-apart sync" "$first" "header kept" || return 1
  run capart config shell personal
  assert_contains "$OUT" "CA_EMOJI='🟪'" "other fields survive" || return 1
}

test_config_add_remove_profile() {
  t_two_profiles
  run capart config add-profile side
  assert_rc 0 "add" || return 1
  run capart config shell side
  assert_contains "$OUT" "CA_DIR='$HOME/.claude-side'" "new profile dir" || return 1
  run capart config set default side
  assert_rc 0 "set default" || return 1
  run capart config remove-profile side
  assert_rc 0 "remove" || return 1
  run capart config profiles
  assert_eq "personal
work" "$OUT" "side removed" || return 1
  run capart config default
  assert_eq "" "$OUT" "default cleared with its profile" || return 1
}

test_cli_unknown_subcommand() {
  run claude-apart frobnicate
  assert_rc 2 "unknown subcommand" || return 1
  assert_contains "$ERR" "Usage" "usage shown" || return 1
  run perl -I"$REPO/lib" "$REPO/libexec/claude-apart/capart.pl" frobnicate
  assert_rc 2 "capart unknown" || return 1
}

test_ca_home_inside_test_dir() {
  case "$CA_HOME" in "$T"/*) ;; *) echo "CA_HOME not under T: $CA_HOME"; return 1;; esac
}

test_cli_through_symlink_finds_root() {
  ln -s "$REPO/bin/claude-apart" "$T/bin/ca"
  run env -u CA_ROOT "$T/bin/ca" help
  assert_rc 0 "help via symlink" || return 1
  assert_contains "$OUT" "Usage" "usage printed" || return 1
  [ -z "$(env | grep '^CA_ROOT=')" ] || { echo "CA_ROOT leaked into env"; return 1; }
}

_cfg_perl() { # <perl code> [args...]: run code with the loaded config in $c
  local code=$1; shift
  run perl -I"$REPO/lib" -MClaudeApart::Config -e 'my $c=ClaudeApart::Config::load(ClaudeApart::Config::config_path()); '"$code" -- "$@"
}

test_config_tmp_dir_state_home() {
  t_two_profiles
  local code='print ClaudeApart::Config::tmp_dir($ARGV[0]), "\n"'
  XDG_STATE_HOME="$T/state" _cfg_perl "$code" work
  assert_eq "$T/state/claude-apart/tmp/work" "$OUT" "absolute XDG_STATE_HOME" || return 1
  XDG_STATE_HOME="relative/state" _cfg_perl "$code" work
  assert_eq "$HOME/.local/state/claude-apart/tmp/work" "$OUT" "relative ignored" || return 1
  XDG_STATE_HOME="" _cfg_perl "$code" work
  assert_eq "$HOME/.local/state/claude-apart/tmp/work" "$OUT" "empty ignored" || return 1
}

test_config_owned_paths_tmp() {
  t_two_profiles
  unset XDG_STATE_HOME XDG_CACHE_HOME
  local code='print "$_\n" for ClaudeApart::Config::owned_paths($c,$ARGV[0])'
  local uid; uid=$(perl -e 'print $<')
  local cache
  if [ "$(uname)" = Darwin ]; then cache="$HOME/Library/Caches/claude-cli-nodejs"; else cache="$HOME/.cache/claude-cli-nodejs"; fi
  _cfg_perl "$code" personal
  assert_contains "$OUT" "$HOME/.local/state/claude-apart/tmp/personal"$'\n' "adopted owns its tmp dir" || return 1
  assert_contains "$OUT" "/tmp/claude-$uid"$'\n' "adopted owns shared temp root" || return 1
  assert_contains "$OUT" "$cache" "adopted owns cache folder" || return 1
  _cfg_perl "$code" work
  assert_contains "$OUT" "$HOME/.local/state/claude-apart/tmp/work" "work owns its tmp dir" || return 1
  assert_not_contains "$OUT" "/tmp/claude-$uid" "work does not own shared root" || return 1
  assert_not_contains "$OUT" "claude-cli-nodejs" "work does not own cache" || return 1
  local wcode='my ($r,$w)=ClaudeApart::Config::foreign_paths($c,$ARGV[0]); print "W:$_\n" for @$w;'
  _cfg_perl "$wcode" work
  assert_contains "$OUT" "W:/tmp/claude-$uid"$'\n' "work: shared root write-denied" || return 1
  assert_contains "$OUT" "W:$cache" "work: cache write-denied" || return 1
}

test_harness_temp_base() { # R48: the suite's temp base is never under /tmp/claude-<uid>, in any spelling
  local uid; uid=$(id -u)
  ln -s /tmp "$T/l"
  assert_eq "$T" "$(TMPDIR=$T _t_base)" "a normal folder is used" || return 1
  assert_eq /var/tmp "$(TMPDIR=/tmp/claude-$uid _t_base)" "the root itself" || return 1
  assert_eq /var/tmp "$(TMPDIR=/private/tmp/claude-$uid/x _t_base)" "/private spelling" || return 1
  assert_eq /var/tmp "$(TMPDIR=$T/l/claude-$uid _t_base)" "through a symlink" || return 1
  assert_eq /var/tmp "$(TMPDIR=$T/missing _t_base)" "a folder that is not there" || return 1
  case "$T" in /tmp/claude-$uid/*|/private/tmp/claude-$uid/*) echo "T is under the session temp root"; return 1;; esac
}
