# claude-apart add <name> [--dir D] [--tag T] [--emoji E] [--colour C] [--adopt]
# Sourced by bin/claude-apart (and by setup). Returns non-zero on any
# problem and leaves no half-made profile behind.

_ca_sh() { . "$CA_ROOT/libexec/claude-apart/cmd/$1.sh"; }

# First palette entry that no existing profile uses: <field> <entry...>.
# An entry is "word" or "word:value" (the config reports a colour as its number).
_ca_free_pick() {
  local field=$1 item p used
  shift
  for item in "$@"; do
    used=0
    for p in $(capart config profiles 2>/dev/null); do
      [ "$(ca_profile_var "$p" "$field")" = "${item##*:}" ] && used=1
    done
    [ "$used" = 0 ] && { echo "${item%%:*}"; return; }
  done
  echo "${1%%:*}"
}

ca_add() {
  local name dir= tag= emoji= colour= adopt=0 cfg had_cfg=0 abs p other
  [ $# -ge 1 ] || { echo "Usage: claude-apart add <name> [--dir D] [--tag T] [--emoji E] [--colour C] [--adopt]" >&2; return 2; }
  name=$1; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --adopt) adopt=1 ;;
      --dir|--tag|--emoji|--colour)
        [ $# -ge 2 ] || { ca_err "$1 needs a value."; return 2; }
        case "$1" in --dir) dir=$2;; --tag) tag=$2;; --emoji) emoji=$2;; --colour) colour=$2;; esac
        shift ;;
      *) ca_err "unknown option: $1"; return 2 ;;
    esac
    shift
  done
  # R14: same rule as the config; checked here so nothing is asked first.
  case "$name" in apart) ca_err "the name 'apart' is not allowed."; return 1;; esac
  printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' \
    || { ca_err "bad profile name '$name' (lowercase letters, digits and dashes; start with a letter; at most 31)."; return 1; }
  cfg=${XDG_CONFIG_HOME:-$HOME/.config}/claude-apart/config
  [ -e "$cfg" ] && had_cfg=1
  if [ "$had_cfg" = 1 ]; then
    for p in $(capart config profiles); do
      [ "$p" = "$name" ] && { ca_err "profile '$name' already exists."; return 1; }
    done
  fi
  if [ "$adopt" = 1 ]; then
    [ -z "$dir" ] || { ca_err "--adopt uses ~/.claude; do not give --dir."; return 1; }
    dir='~/.claude'
  else
    [ -n "$dir" ] || dir="~/.claude-$name"
    case "$dir" in "$HOME"/*) dir="~/${dir#"$HOME"/}" ;; esac
    case "$dir" in /*|"~/"?*) ;; *) ca_err "the folder must be an absolute path (or start with ~/)."; return 1 ;; esac
  fi
  dir=${dir%/}
  abs=$dir
  case "$abs" in "~/"*) abs="$HOME/${abs#"~/"}" ;; esac
  [ "$abs" != "$HOME" ] && [ "$abs" != / ] || { ca_err "that folder cannot be a profile folder."; return 1; }
  if [ "$had_cfg" = 1 ]; then
    for p in $(capart config profiles); do
      other=$(ca_profile_var "$p" DIR)
      [ "$other" = "$abs" ] && { ca_err "that folder is already used by profile $p."; return 1; }
    done
  fi
  [ -n "$tag" ] || tag=$(printf '%s' "$name" | tr 'a-z' 'A-Z' | tr -d - | cut -c1-4)
  if [ -z "$emoji" ]; then
    ask_to emoji "Emoji for $name" "$(_ca_free_pick EMOJI 🟪 🟧 🟦 🟩 🟥 🟨)"
  fi
  if [ -z "$colour" ]; then
    ask_to colour "Colour for $name" "$(_ca_free_pick COLOUR purple:135 orange:208 blue:33 green:40 red:196 yellow:220)"
  fi
  capart config add-profile "$name" "dir=$dir" "tag=$tag" "emoji=$emoji" "colour=$colour" || return 1

  if [ "$adopt" = 1 ]; then
    if ! _ca_adopt_identity "$name"; then
      _ca_add_rollback "$name" "$had_cfg" "$cfg"
      return 1
    fi
  else
    _ca_sh login
    if ! _ca_login_core "$name"; then
      _ca_add_rollback "$name" "$had_cfg" "$cfg"
      return 1
    fi
  fi
  [ -n "$(capart config default)" ] || capart config set default "$name"
  _ca_sh sync
  install_links && ca_sync
}

# Records the account that is already logged in at ~/.claude (no login).
_ca_adopt_identity() { # <name>
  local id email org oname
  id=$(capart identity-read "$1") || { ca_err "no logged-in account found in ~/.claude; log in with plain claude first."; return 1; }
  { IFS= read -r email; IFS= read -r org; IFS= read -r oname; } <<EOF2
$id
EOF2
  if [ -z "$email" ] || [ -z "$org" ]; then
    ca_err "the account in ~/.claude shows no email or organisation; cannot adopt it."
    return 1
  fi
  echo "Found $email (organisation: ${oname:-$org}) in ~/.claude."
  ask_yn "Use this account for $1?" || return 1
  capart config set-profile "$1" email "$email" && capart config set-profile "$1" org "$org"
}

# Undo a half-finished add: the profile goes; the folder and logins stay.
_ca_add_rollback() { # <name> <had_cfg> <cfg file>
  capart config remove-profile "$1" || ca_err "could not remove profile $1 from the config; remove it by hand."
  [ "$2" = 1 ] || rm -f "$3"
}
