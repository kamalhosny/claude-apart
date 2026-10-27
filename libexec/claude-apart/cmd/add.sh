# claude-apart add <name> [--dir D] [--tag T] [--emoji E] [--colour C] [--adopt]
# Sourced by bin/claude-apart (and by setup). rc 0 = added; 1 = not added (no
# half-made profile is left behind); 3 = added, but the final sync failed.

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

# rc 1 when a value has a newline or another control character.
_ca_plain_text() { # <what> <value>
  case "$2" in *[[:cntrl:]]*) ca_err "$1 must not contain a newline or other control character."; return 1;; esac
  case "$2" in [[:space:]]*|*[[:space:]]) ca_err "$1 must not start or end with a space."; return 1;; esac
  return 0
}

ca_add() {
  local name dir= tag= emoji= colour= adopt=0 cfg had_cfg=0 abs p re='^[a-z][a-z0-9-]{0,30}$' fields loaded
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
  # R14: same rule as the config, checked first so nothing is asked before it.
  _ca_plain_text "the name" "$name" && _ca_plain_text "the folder" "$dir" && _ca_plain_text "the tag" "$tag" \
    && _ca_plain_text "the emoji" "$emoji" && _ca_plain_text "the colour" "$colour" || return 1
  [ "$name" != apart ] || { ca_err "the name 'apart' is not allowed."; return 1; }
  [[ $name =~ $re ]] \
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
    case "$dir" in "~/"*) abs="$HOME/${dir#"~/"}" ;; *) abs=$dir ;; esac
    case "$abs" in /*) ;; *) ca_err "the folder must be an absolute path (or start with ~/)."; return 1 ;; esac
    ca_dir_plain "$abs" || { ca_err "the folder must not have a . or .. part."; return 1; }
    abs=${abs%/}
    [ -n "$abs" ] || { ca_err "the folder cannot be /."; return 1; }
    ca_dir_conflict "$abs" "" 0 || return 1
    case "$abs" in "$HOME"/*) dir="~/${abs#"$HOME"/}" ;; *) dir=$abs ;; esac
  fi
  if [ "$adopt" = 1 ]; then
    ca_dir_conflict "$HOME/.claude" "" 1 || return 1
  fi
  if [ -z "$emoji" ]; then
    ask_to emoji "Emoji for $name" "$(_ca_free_pick EMOJI 🟪 🟧 🟦 🟩 🟥 🟨)"
  fi
  if [ -z "$colour" ]; then
    ask_to colour "Colour for $name" "$(_ca_free_pick COLOUR purple:135 orange:208 blue:33 green:40 red:196 yellow:220)"
  fi
  _ca_plain_text "the emoji" "$emoji" && _ca_plain_text "the colour" "$colour" || return 1
  # the tag default (uppercased name, 4 characters) lives in the config code
  fields=("dir=$dir" "emoji=$emoji" "colour=$colour")
  [ -z "$tag" ] || fields[${#fields[@]}]="tag=$tag"
  capart config add-profile "$name" "${fields[@]}" || return 1
  # the saved value is what counts: check the folder as it loads back, before any login
  loaded=$(ca_profile_var "$name" DIR)
  if [ "$adopt" = 1 ]; then
    ca_dir_conflict "$loaded" "$name" 1
  else
    ca_dir_conflict "$loaded" "$name" 0
  fi || { _ca_add_rollback "$name" "$had_cfg" "$cfg"; return 1; }

  if [ "$adopt" = 1 ]; then
    _ca_adopt_identity "$name" || { _ca_add_rollback "$name" "$had_cfg" "$cfg"; return 1; }
  else
    _ca_sh login
    _ca_login_core "$name" || { _ca_add_rollback "$name" "$had_cfg" "$cfg"; return 1; }
  fi
  [ -n "$(capart config default)" ] || capart config set default "$name"
  _ca_sh sync
  if ! ca_sync; then
    ca_err "profile $name was added, but the sync failed; run: claude-apart sync"
    return 3
  fi
}

# Adopting ~/.claude: an account already logged in there is confirmed, never
# logged out; with none, the login runs for it. Both use the duplicate check.
_ca_adopt_identity() { # <name>
  local id email org oname
  _ca_sh login
  if id=$(capart identity-read "$1"); then
    { IFS= read -r email; IFS= read -r org; IFS= read -r oname; } <<EOF2
$id
EOF2
    _ca_confirm_identity "$1" "$email" "$org" "$oname" 0
  else
    echo "No logged-in account found in ~/.claude; logging in."
    _ca_login_core "$1"
  fi
}

# Undo a half-finished add: the profile goes; the folder and logins stay.
_ca_add_rollback() { # <name> <had_cfg> <cfg file>
  capart config remove-profile "$1" || ca_err "could not remove profile $1 from the config; remove it by hand."
  [ "$2" = 1 ] || rm -f "$3"
}
