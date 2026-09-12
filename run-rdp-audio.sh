#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vpn-rdp-container"
PID_FILE="$RUNTIME_DIR/audio-companion.pid"
LOCK_FILE="$RUNTIME_DIR/audio-companion.lock"
AUDIO_FIFO="$RUNTIME_DIR/audio-companion.pcm"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: required command not found: $command_name" >&2
    exit 1
  fi
}

ssh_audio_stream() {
  exec ssh \
    -S none \
    -T \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ClearAllForwardings=yes \
    -o ControlMaster=no \
    -o ControlPath=none \
    -o ControlPersist=no \
    -o SessionType=default \
    vpn-rdp-container \
    stream-audio
}

play_audio_stream() {
  exec pw-play \
    --raw \
    --format=s16 \
    --rate=44100 \
    --channels=2 \
    --channel-map=Stereo \
    --latency=100ms \
    -
}

stream_audio() {
  ssh_audio_stream | play_audio_stream
}

rdp_is_ready() {
  [ -n "$(ss -tnH state established dst 127.0.0.1:3389)" ]
}

run_companion() {
  local pid_tmp ssh_pid="" player_pid="" stream_status

  for required_command in ssh pw-play ss flock mkfifo; do
    require_command "$required_command"
  done

  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Error: the RDP audio companion is already running." >&2
    exit 1
  fi

  pid_tmp="${PID_FILE}.$$"
  printf '%s\n' "$$" > "$pid_tmp"
  mv -f "$pid_tmp" "$PID_FILE"

  cleanup_companion() {
    trap - EXIT HUP INT TERM
    [ -z "$ssh_pid" ] || kill -TERM "$ssh_pid" >/dev/null 2>&1 || true
    [ -z "$player_pid" ] || kill -TERM "$player_pid" >/dev/null 2>&1 || true
    [ -z "$ssh_pid" ] || wait "$ssh_pid" >/dev/null 2>&1 || true
    [ -z "$player_pid" ] || wait "$player_pid" >/dev/null 2>&1 || true
    rm -f "$AUDIO_FIFO"
    rm -f "$PID_FILE"
  }

  trap cleanup_companion EXIT
  trap 'cleanup_companion; exit 129' HUP
  trap 'cleanup_companion; exit 130' INT
  trap 'cleanup_companion; exit 0' TERM

  echo "Waiting for the RustConn RDP session." >&2
  until rdp_is_ready; do
    sleep 0.2
  done
  echo "RDP is ready; split audio is starting." >&2

  rm -f "$AUDIO_FIFO"
  mkfifo -m 600 "$AUDIO_FIFO"
  ssh_audio_stream > "$AUDIO_FIFO" &
  ssh_pid=$!
  play_audio_stream < "$AUDIO_FIFO" &
  player_pid=$!

  set +e
  wait -n "$ssh_pid" "$player_pid"
  stream_status=$?
  set -e

  cleanup_companion
  return "$stream_status"
}

stop_companion() {
  local companion_pid cmdline attempt

  [ -r "$PID_FILE" ] || return 0
  companion_pid="$(< "$PID_FILE")"
  case "$companion_pid" in
    ''|*[!0-9]*)
      rm -f "$PID_FILE"
      return 0
      ;;
  esac

  if [ ! -r "/proc/$companion_pid/cmdline" ]; then
    rm -f "$PID_FILE"
    return 0
  fi
  cmdline="$(tr '\0' '\n' < "/proc/$companion_pid/cmdline")"
  case "$cmdline" in
    *"$SCRIPT_PATH"$'\ncompanion'*) ;;
    *)
      echo "Error: refusing to signal unrelated process $companion_pid." >&2
      rm -f "$PID_FILE"
      return 1
      ;;
  esac

  kill -TERM "$companion_pid"
  for attempt in {1..50}; do
    if [ ! -e "/proc/$companion_pid" ] || [ ! -r "$PID_FILE" ]; then
      return 0
    fi
    sleep 0.1
  done
  echo "Error: audio companion $companion_pid did not stop." >&2
  return 1
}

case "${1:-run}" in
  run)
    require_command ssh
    require_command pw-play
    echo "Streaming split RDP audio; press Ctrl-C to stop and restore the XRDP sink." >&2
    stream_audio
    ;;
  companion)
    run_companion
    ;;
  stop-companion)
    stop_companion
    ;;
  *)
    echo "Usage: $0 [run|companion|stop-companion]" >&2
    exit 2
    ;;
esac
