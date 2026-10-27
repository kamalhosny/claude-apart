#!/bin/sh
# claude-apart installer. Works from a clone (./install.sh) and piped
# (curl -fsSL <url>/install.sh | sh). Installs into your home, no root.
# POSIX sh on purpose, so it runs on macOS and Ubuntu.

CA_DEFAULT_REPO="OWNER/claude-apart"

say() { printf '%s\n' "$*"; }
fail() { printf 'claude-apart: %s\n' "$*" >&2; exit 1; }

# Inside a Claude session this would change what the session runs under.
if [ "${CLAUDE_CODE_CHILD_SESSION:-}" = 1 ]; then
  fail "run this in a normal terminal, not inside Claude."
fi

[ -n "${HOME:-}" ] || fail "HOME is not set."
PREFIX=${CLAUDE_APART_HOME:-$HOME/.local/share/claude-apart}
REPO=${CLAUDE_APART_REPO:-$CA_DEFAULT_REPO}
case "$PREFIX" in /?*) ;; *) fail "the install folder must be an absolute path: $PREFIX" ;; esac

TMP_SRC=
cleanup() { [ -z "$TMP_SRC" ] || rm -rf "$TMP_SRC"; }
trap cleanup EXIT INT TERM

# Where is the code? A clone has lib/ClaudeApart next to this file; when piped
# to sh, $0 is just "sh" and is not a file.
SRC=
if [ -f "$0" ]; then
  d=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)
  if [ -n "$d" ] && [ -d "$d/lib/ClaudeApart" ] && [ -f "$d/bin/claude-apart" ]; then SRC=$d; fi
fi
if [ -z "$SRC" ]; then
  command -v curl >/dev/null 2>&1 || fail "curl is needed to download claude-apart."
  command -v tar >/dev/null 2>&1 || fail "tar is needed to unpack claude-apart."
  TMP_SRC=$(mktemp -d "${TMPDIR:-/tmp}/claude-apart-install.XXXXXX") || fail "cannot make a temp folder."
  URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
  say "Downloading $URL"
  curl -fsSL "$URL" </dev/null | tar -xzf - -C "$TMP_SRC" || fail "download failed."
  for d in "$TMP_SRC"/*; do
    if [ -d "$d/lib/ClaudeApart" ] && [ -f "$d/bin/claude-apart" ]; then SRC=$d; break; fi
  done
  [ -n "$SRC" ] || fail "the download does not look like claude-apart."
fi

mkdir -p "$PREFIX/bin" || fail "cannot make $PREFIX/bin"
real_prefix=$(cd "$PREFIX" && pwd -P)
[ "$real_prefix" != "$SRC" ] || fail "the install folder is the folder you are installing from."

# Replace the code; the claude and claude-<name> links in bin/ stay.
rm -rf "$PREFIX/libexec" "$PREFIX/lib" "$PREFIX/bin/claude-apart"
cp -R "$SRC/libexec" "$PREFIX/libexec" || fail "copy failed."
cp -R "$SRC/lib" "$PREFIX/lib" || fail "copy failed."
cp "$SRC/bin/claude-apart" "$PREFIX/bin/claude-apart" || fail "copy failed."
chmod 755 "$PREFIX/bin/claude-apart"
say "Installed claude-apart into $PREFIX"

# PATH line in the shell startup files. Appending (>>) keeps a symlinked file
# (dotfiles repo) a symlink and keeps its mode.
LINE="export PATH=\"$PREFIX/bin:\$PATH\"  # claude-apart"
add_line() { # <file>
  if grep -qxF -- "$LINE" "$1" 2>/dev/null; then return 0; fi
  # a last line without a newline must not swallow ours
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then printf '\n' >> "$1"; fi
  printf '%s\n' "$LINE" >> "$1" || fail "cannot write to $1"
  say "Added the PATH line to $1"
}
found=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [ -e "$rc" ]; then found=1; add_line "$rc"; fi
done
if [ "$found" = 0 ]; then add_line "$HOME/.zshrc"; fi

# Already set up: re-pin the hooks to the new copy. Otherwise say what is next.
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/claude-apart/config" ]; then
  say "Updating the hooks in your profiles."
  "$PREFIX/bin/claude-apart" sync </dev/null || fail "sync failed; run: claude-apart sync"
else
  say ""
  say "Next step (open a new terminal first):"
  say "  claude-apart setup"
fi
