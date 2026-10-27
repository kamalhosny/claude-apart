# Tests for install.sh and claude-apart uninstall. Everything runs under $T.

_marked() { printf 'export PATH="%s/bin:$PATH"  # claude-apart' "$CLAUDE_APART_HOME"; }
_count() { grep -cF -- "$2" "$1" || true; }

_jeq() { # <file a> <file b>: deep-equal JSON
  perl -MJSON::PP -e 'sub rd { local $/; open my $f, "<", $_[0] or die; JSON::PP->new->utf8->canonical->encode(JSON::PP->new->utf8->decode(<$f>)) } exit(rd($ARGV[0]) eq rd($ARGV[1]) ? 0 : 1)' "$1" "$2"
}

test_install_from_clone() {
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  [ -x "$T/prefix/bin/claude-apart" ] || { echo "no executable claude-apart"; return 1; }
  [ -d "$T/prefix/lib/ClaudeApart" ] && [ -x "$T/prefix/libexec/claude-apart/wrapper.sh" ] || { echo "lib or libexec missing"; return 1; }
  [ ! -e "$HOME/.local/bin" ] || { echo "touched ~/.local/bin"; return 1; }
  assert_contains "$OUT" "claude-apart setup" "next step" || return 1
  run "$REPO/install.sh"; assert_rc 0 "install again" || return 1
  [ "$(_count "$HOME/.zshrc" "$(_marked)")" = 1 ] || { echo "marked line count:"; cat "$HOME/.zshrc"; return 1; }
  [ ! -e "$HOME/.bashrc" ] || { echo ".bashrc created"; return 1; }
  # the installed copy runs
  run "$T/prefix/bin/claude-apart" help; assert_rc 0 "installed help" || return 1
}

test_install_both_rc_files_when_they_exist() {
  : > "$HOME/.bashrc"; printf 'alias x=y' > "$HOME/.zshrc"   # no trailing newline
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  [ "$(_count "$HOME/.bashrc" "$(_marked)")" = 1 ] || { echo "bashrc"; return 1; }
  [ "$(_count "$HOME/.zshrc" "$(_marked)")" = 1 ] || { echo "zshrc"; return 1; }
  assert_eq "alias x=y" "$(sed -n 1p "$HOME/.zshrc")" "old line kept on its own line" || return 1
}

test_install_refused_inside_session() {
  CLAUDE_CODE_CHILD_SESSION=1 run "$REPO/install.sh"
  assert_rc 1 "refused" || return 1
  assert_contains "$ERR" "run this in a normal terminal, not inside Claude." "message" || return 1
  [ ! -e "$T/prefix/bin/claude-apart" ] || { echo "installed anyway"; return 1; }
}

test_reinstall_keeps_links_and_syncs() {
  t_two_profiles
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  assert_not_contains "$OUT" "claude-apart setup" "no setup hint when configured" || return 1
  ln -s "$T/prefix/libexec/claude-apart/wrapper.sh" "$T/prefix/bin/claude-work"
  touch "$T/prefix/lib/stale-file"
  run "$REPO/install.sh"; assert_rc 0 "reinstall" || return 1
  [ -L "$T/prefix/bin/claude-work" ] || { echo "link lost"; return 1; }
  [ ! -e "$T/prefix/lib/stale-file" ] || { echo "lib not replaced"; return 1; }
  # sync re-pinned the hooks to the installed copy
  assert_contains "$(cat "$HOME/.claude-work/settings.json")" "$T/prefix/" "hooks name the prefix" || return 1
}

test_install_from_pipe_builds_url() {
  mkdir -p "$T/src/claude-apart-main"
  cp -R "$REPO/bin" "$REPO/lib" "$REPO/libexec" "$T/src/claude-apart-main/"
  tar -C "$T/src" -czf "$T/main.tar.gz" claude-apart-main
  cat > "$T/bin/curl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/curl.log"
cat "$T/main.tar.gz"
EOF
  chmod +x "$T/bin/curl"
  CLAUDE_APART_REPO=someone/claude-apart run sh -c "cd '$T' && sh < '$REPO/install.sh'"
  assert_rc 0 "piped install" || return 1
  assert_contains "$(cat "$T/curl.log")" "https://github.com/someone/claude-apart/archive/refs/heads/main.tar.gz" "url" || return 1
  [ -x "$T/prefix/bin/claude-apart" ] || { echo "not installed"; return 1; }
}

test_install_default_repo_is_one_line() {
  [ "$(grep -c 'OWNER/claude-apart' "$REPO/install.sh")" = 1 ] || { echo "OWNER must appear on exactly one line"; return 1; }
}

_seed_settings() {
  cat > "$HOME/.claude-work/settings.json" <<'JSON'
{"model":"x","permissions":{"deny":["Bash(ls *)"]},"statusLine":{"type":"command","command":"my-status"},"theme":"light"}
JSON
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"my-hook"}]}]}}
JSON
  cp "$HOME/.claude-work/settings.json" "$T/seed-work.json"
  cp "$HOME/.claude/settings.json" "$T/seed-personal.json"
}

test_uninstall_restores() {
  t_two_profiles
  _seed_settings
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  run "$T/prefix/bin/claude-apart" sync; assert_rc 0 "sync" || return 1
  if _jeq "$HOME/.claude-work/settings.json" "$T/seed-work.json"; then echo "sync changed nothing"; return 1; fi
  run "$T/prefix/bin/claude-apart" uninstall; assert_rc 0 "uninstall" || return 1
  _jeq "$HOME/.claude-work/settings.json" "$T/seed-work.json" || { echo "work not restored"; cat "$HOME/.claude-work/settings.json"; return 1; }
  _jeq "$HOME/.claude/settings.json" "$T/seed-personal.json" || { echo "personal not restored"; return 1; }
  [ "$(_count "$HOME/.zshrc" "# claude-apart")" = 0 ] || { echo "rc line left"; return 1; }
  [ ! -e "$T/prefix" ] || { echo "prefix left:"; ls -R "$T/prefix"; return 1; }
  [ -d "$HOME/.claude" ] && [ -d "$HOME/.claude-work" ] || { echo "profile dir lost"; return 1; }
  [ -f "$HOME/.claude-work/.claude.json" ] || { echo "login lost"; return 1; }
  [ -f "$XDG_CONFIG_HOME/claude-apart/config" ] || { echo "config removed without --purge"; return 1; }
}

test_uninstall_purge_asks_first() {
  t_two_profiles
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  mkdir -p "$HOME/.local/state/claude-apart/tmp/work"
  run bash -c "printf 'n\nn\n' | '$T/prefix/bin/claude-apart' uninstall --purge"; assert_rc 0 "purge, answers no" || return 1
  [ -d "$XDG_CONFIG_HOME/claude-apart" ] && [ -d "$HOME/.local/state/claude-apart" ] || { echo "removed despite no"; return 1; }
  run "$REPO/install.sh"; assert_rc 0 "install again" || return 1
  run bash -c "printf 'y\ny\n' | '$T/prefix/bin/claude-apart' uninstall --purge"; assert_rc 0 "purge, answers yes" || return 1
  [ ! -e "$XDG_CONFIG_HOME/claude-apart" ] || { echo "config left"; return 1; }
  [ ! -e "$HOME/.local/state/claude-apart" ] || { echo "temp folders left"; return 1; }
  [ -d "$HOME/.claude-work" ] && [ -f "$HOME/.claude-work/.claude.json" ] || { echo "profile lost"; return 1; }
}

test_uninstall_refused_inside_session() {
  t_two_profiles
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  CLAUDE_CODE_CHILD_SESSION=1 run "$T/prefix/bin/claude-apart" uninstall
  assert_rc 1 "refused" || return 1
  [ -x "$T/prefix/bin/claude-apart" ] || { echo "removed anyway"; return 1; }
}

test_rc_symlink_stays_a_symlink() {
  mkdir -p "$HOME/dotfiles"
  printf 'alias a=b\n# keep\n' > "$HOME/dotfiles/zshrc"
  chmod 640 "$HOME/dotfiles/zshrc"
  cp "$HOME/dotfiles/zshrc" "$T/zshrc.orig"
  ln -s dotfiles/zshrc "$HOME/.zshrc"
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  [ -L "$HOME/.zshrc" ] || { echo "symlink replaced after install"; return 1; }
  assert_eq "dotfiles/zshrc" "$(readlink "$HOME/.zshrc")" "link target" || return 1
  [ "$(_count "$HOME/dotfiles/zshrc" "$(_marked)")" = 1 ] || { echo "line not added to real file"; return 1; }
  assert_eq "alias a=b" "$(sed -n 1p "$HOME/dotfiles/zshrc")" "old content" || return 1
  run "$T/prefix/bin/claude-apart" uninstall; assert_rc 0 "uninstall" || return 1
  [ -L "$HOME/.zshrc" ] || { echo "symlink replaced after uninstall"; return 1; }
  cmp "$HOME/dotfiles/zshrc" "$T/zshrc.orig" || { echo "real file changed beyond the marked line"; cat "$HOME/dotfiles/zshrc"; return 1; }
  assert_eq "-rw-r-----" "$(ls -l "$HOME/dotfiles/zshrc" | cut -c1-10)" "mode kept" || return 1
}

test_uninstall_corrupt_config_stops() {
  t_two_profiles
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  printf '[profile\nthis is = = not a config\n\x01\n' > "$XDG_CONFIG_HOME/claude-apart/config"
  run "$T/prefix/bin/claude-apart" uninstall
  assert_rc 1 "stops" || return 1
  [ -x "$T/prefix/bin/claude-apart" ] || { echo "copy removed"; return 1; }
  [ "$(_count "$HOME/.zshrc" "# claude-apart")" = 1 ] || { echo "rc line removed"; return 1; }
}

test_uninstall_stops_when_one_profile_fails() {
  t_two_profiles
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  printf '{ not json' > "$HOME/.claude-work/settings.json"
  run "$T/prefix/bin/claude-apart" uninstall
  assert_rc 1 "stops" || return 1
  [ -x "$T/prefix/bin/claude-apart" ] || { echo "copy removed"; return 1; }
  [ "$(_count "$HOME/.zshrc" "# claude-apart")" = 1 ] || { echo "rc line removed"; return 1; }
}

test_uninstall_twice_is_harmless() {
  t_two_profiles
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  run "$T/prefix/bin/claude-apart" uninstall; assert_rc 0 "first" || return 1
  run "$REPO/bin/claude-apart" uninstall; assert_rc 0 "second" || return 1
}

test_uninstall_refuses_when_prefix_is_the_clone() {
  mkdir "$T/clone" && cp -R "$REPO/bin" "$REPO/lib" "$REPO/libexec" "$REPO/install.sh" "$T/clone/"   # a copy, never the real repo
  CLAUDE_APART_HOME="$T/clone" run "$T/clone/bin/claude-apart" uninstall
  assert_rc 1 "refused" || return 1
  [ -d "$T/clone/lib/ClaudeApart" ] && [ -x "$T/clone/bin/claude-apart" ] || { echo "clone damaged"; return 1; }
}

test_failed_copy_keeps_the_old_install() {
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  echo old > "$T/prefix/lib/marker"
  cat > "$T/bin/cp" <<'EOF2'
#!/bin/sh
case "$*" in *libexec*) exit 1 ;; esac
exec /bin/cp "$@"
EOF2
  chmod +x "$T/bin/cp"
  run "$REPO/install.sh"
  assert_rc 1 "install fails" || return 1
  assert_contains "$ERR" "install failed; run install.sh again." "message" || return 1
  [ -f "$T/prefix/lib/marker" ] && [ -x "$T/prefix/bin/claude-apart" ] && [ -d "$T/prefix/libexec" ] || { echo "old copy damaged"; return 1; }
  [ -z "$(ls -A "$T/prefix" | grep '^\.install')" ] || { echo "stage left"; return 1; }
}

test_rc_files_without_final_newline_round_trip() {
  printf 'alias a=b\nexport PATH="%s/bin:$PATH"  # claude-apart\nlast line no newline' "$T/prefix" > "$HOME/.bashrc"
  cp "$HOME/.bashrc" "$T/bashrc.orig"
  run "$REPO/install.sh"; assert_rc 0 "install" || return 1
  [ "$(_count "$HOME/.bashrc" "# claude-apart")" = 1 ] || { echo "line added twice"; return 1; }
  run "$T/prefix/bin/claude-apart" uninstall; assert_rc 0 "uninstall" || return 1
  printf 'alias a=b\nlast line no newline' > "$T/bashrc.want"
  cmp "$HOME/.bashrc" "$T/bashrc.want" || { echo "bytes changed:"; od -c "$HOME/.bashrc" | tail -3; return 1; }
  # marked line as the very last line, without newline
  printf 'alias a=b\nexport PATH="%s/bin:$PATH"  # claude-apart' "$T/prefix" > "$HOME/.bashrc"
  run "$REPO/install.sh"; assert_rc 0 "install 2" || return 1
  run "$T/prefix/bin/claude-apart" uninstall; assert_rc 0 "uninstall 2" || return 1
  assert_eq "alias a=b" "$(cat "$HOME/.bashrc")" "last-line case" || return 1
}
