#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ./client.env ]; then
  echo "Error: missing $SCRIPT_DIR/client.env" >&2
  echo "Create it with USERNAME=... and PASSWORD=..." >&2
  exit 1
fi

set -a
source ./client.env
set +a

: "${USERNAME:?client.env must set USERNAME}"
: "${PASSWORD:?client.env must set PASSWORD}"
RDP_ADDRESS="${WORKSPACE:-}"
if [ -n "${WORKSPACE_IP:-}" ]; then
  RDP_ADDRESS="$WORKSPACE_IP"
fi
[ -n "$RDP_ADDRESS" ] || { echo "Error: client.env must set WORKSPACE, or WORKSPACE_IP as an override." >&2; exit 1; }


if ! ip link show tun0 >/dev/null 2>&1; then
  echo "Error: tun0 is missing. Start the VPN first with ./vpn.sh." >&2
  exit 1
fi

tun0_mtu=$(
  ip -o -j link show tun0 | python3 -c '
import sys, json
ip_links = json.load(sys.stdin)
print(ip_links[0].get("mtu"))
'
)

if [ "$tun0_mtu" != "1280" ]; then
  printf "\nChanging tun0 MTU from %s to 1280: " "$tun0_mtu"
  sudo ip link set dev tun0 mtu 1280
  printf "Done!\n\n"
fi

SERVER_RES="${SERVER_RES:-960x540}"
CLIENT_RES="${CLIENT_RES:-1920x1080}"
RDP_NETWORK="${RDP_NETWORK:-broadband-high}"
FREERDP_LOG="${FREERDP_LOG:-$SCRIPT_DIR/xfreerdp.log}"
RDP_MICROPHONE="${RDP_MICROPHONE:-0}"
RDP_MIC_SOURCE="${RDP_MIC_SOURCE:-}"
RDP_MUTE_INPUTS="${RDP_MUTE_INPUTS:-0}"

flag_enabled() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

pulse_source_exists() {
  pactl list short sources 2>/dev/null | awk '{print $2}' | grep -Fxq "$1"
}

ensure_pulse_source() {
  [ -n "$RDP_MIC_SOURCE" ] || return 0

  if ! pulse_source_exists "$RDP_MIC_SOURCE" && [ "$RDP_MIC_SOURCE" = silence_null.monitor ]; then
    pactl load-module module-null-sink sink_name=silence_null sink_properties=device.description=Silence >/dev/null
  fi

  if ! pulse_source_exists "$RDP_MIC_SOURCE"; then
    echo "Error: configured microphone source not available: $RDP_MIC_SOURCE" >&2
    exit 1
  fi

  pactl set-default-source "$RDP_MIC_SOURCE"
  export PULSE_SOURCE="$RDP_MIC_SOURCE"
  echo "FreeRDP microphone source: $RDP_MIC_SOURCE"
}

mute_audio_inputs() {
  pactl list short sources 2>/dev/null | awk '{print $2}' | while read -r source_name; do
    pactl set-source-mute "$source_name" 1 >/dev/null 2>&1 || true
  done
}

if command -v xfreerdp3 >/dev/null 2>&1; then
  FREERDP=xfreerdp3
elif command -v xfreerdp >/dev/null 2>&1; then
  FREERDP=xfreerdp
else
  echo "Error: xfreerdp3/xfreerdp is not installed." >&2
  exit 1
fi

microphone_args=()
if flag_enabled "$RDP_MUTE_INPUTS"; then
  mute_audio_inputs
fi
if flag_enabled "$RDP_MICROPHONE"; then
  ensure_pulse_source
  microphone_args=(/microphone:sys:pulse)
fi

printf '%s\n' "$PASSWORD" | "$FREERDP" /from-stdin:force /v:"$RDP_ADDRESS" /u:"$USERNAME" /cert:ignore \
  /log-level:INFO \
  /audio-mode:redirect \
  /sound:sys:pulse \
  "${microphone_args[@]}" \
  /network:"$RDP_NETWORK" /timeout:60000 \
  /compression-level:2 \
  /size:"$SERVER_RES" /smart-sizing:"$CLIENT_RES" /f \
  /bpp:16 \
  /gfx:RFX:on,progressive:on,thin-client:on,small-cache:on \
  /frame-ack:120 \
  /gdi:sw \
  +auto-reconnect /auto-reconnect-max-retries:3 \
  +async-update /cache:bitmap:on,glyph:on,offscreen:on \
  -decorations -fonts -themes -wallpaper \
  2>&1 | tee "$FREERDP_LOG"
