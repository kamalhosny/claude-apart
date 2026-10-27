# claude-apart setup: the guided run. Answers come from stdin, so a script can
# pipe them. At end of input it stops with rc 1 and never loops.
# Sourced by bin/claude-apart.

_ca_setup_load() {
  local c
  for c in sync check login add remove; do . "$CA_ROOT/libexec/claude-apart/cmd/$c.sh"; done
}

# rc 1 (and a note) once a prompt has hit the end of input.
_ca_eof_stop() {
  [ "$CA_EOF" = 0 ] && return 0
  echo >&2
  ca_err "no more input; stopped. Run claude-apart setup again to continue."
  return 1
}

# For every ordered pair (A, B): may A read B's things? Current answer is the default.
_ca_grants() {
  local a b cur list cur_yes specs=()
  for a in $(capart config profiles); do
    list=
    cur=$(ca_profile_var "$a" CAN_READ)
    for b in $(capart config profiles); do
      [ "$a" = "$b" ] && continue
      case " $cur " in *" $b "*) cur_yes=y;; *) cur_yes=n;; esac
      ask_yn "May $a read $b's things?" "$cur_yes" && list="$list $b"
      _ca_eof_stop || return 1
    done
    specs[${#specs[@]}]="$a.can_read=${list# }"
  done
  # all answers are in: one write (nothing changes if the input ended early)
  [ ${#specs[@]} -eq 0 ] || capart config set-fields "${specs[@]}"
}

# Runs add and says what happened (rc 3 = added, sync failed).
_ca_add_say() {
  ca_add "$@"
  case $? in
    0) ;;
    3) echo "Profile added; run claude-apart sync to finish." ;;
    *) echo "Profile not added." ;;
  esac
}

_ca_resync() { ca_sync; }    # ca_sync makes the launchers too (F13)

_ca_choose_default() {
  local names cur d
  names=$(capart config profiles | tr '\n' ' ')
  cur=$(capart config default)
  [ -n "$cur" ] || cur=$(capart config profiles | head -n 1)
  while :; do
    ask_to d "Default profile (plain claude outside Herdr uses it): ${names% }" "$cur"
    _ca_eof_stop || return 1
    if capart config profiles | grep -qx -- "$d"; then
      capart config set default "$d"
      return $?
    fi
    ca_err "no such profile: $d"
  done
}

_ca_setup_menu() {
  local c n
  while :; do
    echo
    capart status
    ask_to c "Choose: add / remove / grants / default / sync / done" done
    _ca_eof_stop || return 1
    case "$c" in
      add)
        ask_to n "Name of the new profile" ""
        _ca_eof_stop || return 1
        [ -z "$n" ] || _ca_add_say "$n" ;;
      remove)
        ask_to n "Profile to remove" ""
        _ca_eof_stop || return 1
        [ -z "$n" ] || ca_remove "$n" || echo "Profile not removed." ;;
      grants) _ca_grants || return 1; _ca_resync; ca_restart_note ;;
      default) _ca_choose_default || return 1 ;;
      sync) _ca_resync; ca_restart_note ;;
      done|"") return 0 ;;
      *) echo "Not a choice: $c" ;;
    esac
  done
}

ca_setup() {
  local n
  [ $# -eq 0 ] || { echo "Usage: claude-apart setup" >&2; return 2; }
  _ca_setup_load
  # 1. prerequisites
  find_real_claude >/dev/null || return 1
  perl -MJSON::PP -e1 2>/dev/null || { ca_err "perl with JSON::PP is needed."; return 1; }

  if [ -n "$(capart config profiles 2>/dev/null)" ]; then
    _ca_setup_menu
    return $?
  fi

  # 2. adopt ~/.claude
  echo "Anything that starts claude without the launcher uses ~/.claude, so it is"
  echo "best to adopt ~/.claude for your private account (a miss then lands there)."
  # offered even with no login there yet: add then runs the login for it
  if ask_yn "Adopt ~/.claude as a profile?" y; then
    ask_to n "Name for it" personal
    _ca_eof_stop || return 1
    _ca_add_say "$n" --adopt
  fi
  _ca_eof_stop || return 1

  # 3. more profiles
  while :; do
    ask_to n "Add a profile? Name, or Enter to finish" ""
    _ca_eof_stop || return 1
    [ -n "$n" ] || break
    _ca_add_say "$n"
    _ca_eof_stop || return 1
  done
  [ -n "$(capart config profiles 2>/dev/null)" ] || { ca_err "no profile was added."; return 1; }

  # 4. default, 5. grants
  _ca_choose_default || return 1
  _ca_grants || return 1

  # 6. launchers, 7. settings, 8. self-check, 9. open sessions
  _ca_resync || return 1
  ca_check
  n=$?
  ca_restart_note
  return "$n"
}
