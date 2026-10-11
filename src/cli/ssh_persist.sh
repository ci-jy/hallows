#!/bin/sh
# Remote half of `ghostty +ssh --persist` (the `ssh-persist` shell integration
# feature). `+ssh` installs this as ~/.local/share/ghostty/ssh-persist and runs
# it as the remote command of every connection attempt:
#
#   ssh-persist attach TAG      attach the terminal tab identified by TAG
#   ssh-persist record PID NAME tmux hook: client PID is now on session NAME
#
# TAG is random per `+ssh` invocation and reused on every reconnect, so a
# dropped connection lands back on whichever tmux session that tab was last
# showing. The tmux client carries TAG in its environment, and a global hook
# records the client's session whenever it changes.
set -eu

state="${XDG_STATE_HOME:-$HOME/.local/state}/ghostty/ssh-persist"
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Everything Ghostty supports that tmux can use. Terminal features are read
# when a client attaches, so this has to be set before we attach.
ghostty_features="xterm-ghostty:RGB:sync:hyperlinks:usstyle:strikethrough:overline:bpaste:clipboard:ccolour:cstyle:focus:title:extkeys"

valid_tag() {
  case "$1" in
  '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
}

# Run a command that may start the tmux server inside a systemd user scope.
# Otherwise the server inherits the ssh session's cgroup and can be killed
# along with it, e.g. when tailscaled (Tailscale SSH) restarts for an update.
in_user_scope() {
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
  fi
  if command -v systemd-run >/dev/null 2>&1 &&
    systemd-run --user --scope --quiet true >/dev/null 2>&1; then
    systemd-run --user --scope --quiet "$@"
  else
    "$@"
  fi
}

case "${1:-}" in
attach)
  tag=${2:-}
  valid_tag "$tag" || { echo "ssh-persist: invalid tag" >&2; exit 2; }
  mkdir -p "$state"
  # Forget tabs that haven't been used in a month.
  find "$state" -type f -mtime +30 -delete 2>/dev/null || true

  session=$(cat "$state/$tag" 2>/dev/null || true)
  # Don't resurrect a session that was killed while we were disconnected.
  if [ -n "$session" ] && ! tmux has-session -t "=$session" 2>/dev/null; then
    session=
  fi

  # With nothing remembered, attach to the most recent session, starting
  # the server (and a first session) if needed.
  if [ -z "$session" ] && ! tmux has-session 2>/dev/null; then
    session=$(in_user_scope tmux new-session -d -P -F '#{session_name}')
  fi

  case "$(tmux show-options -sv terminal-features 2>/dev/null)" in
  *xterm-ghostty:*) ;;
  *) tmux set-option -as terminal-features "$ghostty_features" ;;
  esac

  # Reset the window title in case +ssh set "reconnecting" in it.
  printf '\033]2;%s\007' "$(hostname)"

  if [ -n "$session" ]; then
    set -- attach-session -t "=$session"
  else
    set -- attach-session
  fi
  record="run-shell -b \"'$self' record #{client_pid} #{q:session_name}\""
  GHOSTTY_SSH_TAG="$tag"
  export GHOSTTY_SSH_TAG
  exec tmux "$@" \
    \; set-hook -g 'client-session-changed[100]' "$record" \
    \; run-shell -b "'$self' record #{client_pid} #{q:session_name}"
  ;;
record)
  # Linux only; elsewhere, reconnects fall back to the most recent session.
  tag=$(tr '\0' '\n' <"/proc/${2:-0}/environ" 2>/dev/null |
    sed -n 's/^GHOSTTY_SSH_TAG=//p')
  valid_tag "$tag" || exit 0
  mkdir -p "$state"
  printf '%s\n' "$3" >"$state/$tag"
  ;;
*)
  echo "usage: ssh-persist attach TAG" >&2
  exit 2
  ;;
esac
