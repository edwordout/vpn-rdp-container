#!/bin/sh
set -eu

if [ "${SSH_ORIGINAL_COMMAND:-}" != stream-audio ]; then
  echo "Error: this SSH key only supports the stream-audio command." >&2
  exit 1
fi

XDG_RUNTIME_DIR="/run/user/$(id -u)"
PULSE_SERVER="unix:${XDG_RUNTIME_DIR}/pulse/native"
export XDG_RUNTIME_DIR PULSE_SERVER

if ! pactl info >/dev/null 2>&1; then
  echo "Error: PipeWire/Pulse is unavailable; connect the outer XRDP session first." >&2
  exit 1
fi

if pactl list short sinks | awk '$2 == "ssh_audio" { found = 1 } END { exit !found }'; then
  echo "Error: ssh_audio already exists; stop the prior split-audio process." >&2
  exit 1
fi

previous_default_sink="$(pactl get-default-sink)"
module_id=""
cleaned_up=0
event_fifo="${XDG_RUNTIME_DIR}/vpn-rdp-audio-events.$$"
subscribe_pid=""
router_pid=""

move_sink_inputs() {
  destination="$1"
  destination_id="$(
    pactl list short sinks 2>/dev/null |
      awk -v sink_name="$destination" '$2 == sink_name { print $1; exit }'
  )"
  [ -n "$destination_id" ] || return 0

  pactl list short sink-inputs 2>/dev/null |
    while IFS="$(printf '\t')" read -r input_id current_sink_id _; do
      [ -n "$input_id" ] || continue
      [ "$current_sink_id" = "$destination_id" ] && continue
      pactl move-sink-input "$input_id" "$destination" >/dev/null 2>&1 || true
    done
}

route_new_sink_inputs() {
  while IFS= read -r event; do
    case "$event" in
      *sink-input*) move_sink_inputs ssh_audio ;;
    esac
  done
}

cleanup() {
  [ "$cleaned_up" -eq 0 ] || return 0
  cleaned_up=1
  [ -z "$subscribe_pid" ] || kill -TERM "$subscribe_pid" >/dev/null 2>&1 || true
  [ -z "$router_pid" ] || kill -TERM "$router_pid" >/dev/null 2>&1 || true
  [ -z "$subscribe_pid" ] || wait "$subscribe_pid" >/dev/null 2>&1 || true
  [ -z "$router_pid" ] || wait "$router_pid" >/dev/null 2>&1 || true
  rm -f "$event_fifo"

  if [ -n "$previous_default_sink" ]; then
    pactl set-default-sink "$previous_default_sink" >/dev/null 2>&1 || true
    move_sink_inputs "$previous_default_sink"
  fi
  if [ -n "$module_id" ]; then
    pactl unload-module "$module_id" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

module_id="$(pactl load-module module-null-sink \
  sink_name=ssh_audio \
  rate=44100 \
  channels=2 \
  channel_map=front-left,front-right \
  sink_properties=device.description=Dedicated_SSH_Audio)"

pactl set-default-sink ssh_audio >/dev/null
move_sink_inputs ssh_audio
rm -f "$event_fifo"
mkfifo -m 600 "$event_fifo"
pactl subscribe >"$event_fifo" 2>/dev/null &
subscribe_pid=$!
route_new_sink_inputs <"$event_fifo" &
router_pid=$!
move_sink_inputs ssh_audio

parec --device=ssh_audio.monitor --raw --format=s16le --rate=44100 --channels=2
