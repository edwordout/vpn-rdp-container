#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/run-rdp-container.log"
exec > >(tee "$LOG_FILE") 2>&1

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/run-rdp-container.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: missing $ENV_FILE. Copy run-rdp-container.env.example to run-rdp-container.env and edit it." >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?HOSTNAME[[:space:]]*=' "$ENV_FILE"; then
  echo "Error: use CONTAINER_HOSTNAME in $ENV_FILE, not HOSTNAME." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

APP_NAME="${APP_NAME:-vpn-rdp}"
IMAGE_TAG="${IMAGE_TAG:-stable}"
IMAGE_NAME="${IMAGE_NAME:-${APP_NAME}:${IMAGE_TAG}}"
CONTAINER_NAME="${CONTAINER_NAME:-${APP_NAME}}"
CONTAINER_HOSTNAME="${CONTAINER_HOSTNAME:-$APP_NAME}"
BUILD_CONTEXT="${BUILD_CONTEXT:-$SCRIPT_DIR}"
BUILD_CONTEXT="$(cd "$BUILD_CONTEXT" && pwd)"
BUILD_FILE="${BUILD_FILE:-}"

PODMAN="${PODMAN:-podman}"
REBUILD="${REBUILD:-0}"
RECREATE="${RECREATE:-0}"
PARENT_IFACE="${PARENT_IFACE:-}"
CONTAINER_MAC="${CONTAINER_MAC:-}"
NETWORK_NAME="${NETWORK_NAME:-}"

USER_HOME_TEMPLATE_DIR="${USER_HOME_TEMPLATE_DIR:-$BUILD_CONTEXT/user_home_template}"
CLIENT_DIR="${CLIENT_DIR:-$BUILD_CONTEXT/user_home_volume}"
FIX_HOME_OWNERSHIP="${FIX_HOME_OWNERSHIP:-1}"
# Must match the UID/GID created in the image.
CONTAINER_USER_UID=1000
CONTAINER_USER_GID=1000

fail() {
  echo "Error: $*" >&2
  exit 1
}

podman_exists() {
  local object_type="$1"
  local object_name="$2"
  local output status

  set +e
  output="$("$PODMAN" "$object_type" exists "$object_name" 2>&1)"
  status=$?
  set -e

  [ "$status" = 0 ] && return 0
  [ "$status" = 1 ] && [ -z "$output" ] && return 1
  [ -n "$output" ] && printf '%s\n' "$output" >&2
  fail "podman $object_type exists check failed for $object_name."
}

[ -n "${RDP_USER:-}" ] || fail "RDP_USER is not set in $ENV_FILE"
[ -n "${RDP_PASSWORD:-}" ] || fail "RDP_PASSWORD is not set in $ENV_FILE"
[ -n "$CONTAINER_HOSTNAME" ] || fail "CONTAINER_HOSTNAME is empty in $ENV_FILE"
[ -n "$PARENT_IFACE" ] || fail "PARENT_IFACE is not set in $ENV_FILE"
[ -n "$CONTAINER_MAC" ] || fail "CONTAINER_MAC is not set in $ENV_FILE"
[[ "$CONTAINER_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || fail "CONTAINER_MAC is invalid: $CONTAINER_MAC"
NETWORK_NAME="${NETWORK_NAME:-${APP_NAME}_macvlan_dhcp_${PARENT_IFACE}}"
CLIENT_MOUNT="${CLIENT_MOUNT:-/home/${RDP_USER}}"

[ "$(id -u)" = 0 ] || fail "macvlan-dhcp requires rootful Podman. Run: sudo ./run-rdp-container.sh"
command -v "$PODMAN" >/dev/null 2>&1 || fail "podman is not installed or not in PATH."
command -v ip >/dev/null 2>&1 || fail "iproute2 is required."
ip link show "$PARENT_IFACE" >/dev/null 2>&1 || fail "host interface not found: $PARENT_IFACE"

if [ ! -e /dev/net/tun ]; then
  echo "Preparing /dev/net/tun..."
  command -v modprobe >/dev/null 2>&1 || fail "/dev/net/tun is missing and modprobe is not available."
  modprobe tun || fail "could not load tun kernel module."
fi
if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || fail "could not create /dev/net/tun device node."
  chmod 666 /dev/net/tun
fi
[ -c /dev/net/tun ] || fail "/dev/net/tun exists but is not a character device."

command -v systemctl >/dev/null 2>&1 || fail "systemctl is required to enable netavark DHCP proxy."
[ -d /run/systemd/system ] || fail "systemd is not running; cannot enable netavark DHCP proxy."
if ! systemctl is-active --quiet netavark-dhcp-proxy.socket; then
  echo "Enabling netavark DHCP proxy..."
  systemctl enable --now netavark-dhcp-proxy.socket \
    || fail "could not enable netavark-dhcp-proxy.socket"
fi

if [ -z "$BUILD_FILE" ]; then
  if [ -f "$BUILD_CONTEXT/Containerfile" ]; then
    BUILD_FILE="$BUILD_CONTEXT/Containerfile"
  elif [ -f "$BUILD_CONTEXT/Dockerfile" ]; then
    BUILD_FILE="$BUILD_CONTEXT/Dockerfile"
  else
    fail "no Containerfile or Dockerfile found in $BUILD_CONTEXT"
  fi
fi

[ -d "$USER_HOME_TEMPLATE_DIR" ] || fail "user home template not found: $USER_HOME_TEMPLATE_DIR"
USER_HOME_TEMPLATE_DIR="$(cd "$USER_HOME_TEMPLATE_DIR" && pwd)"
mkdir -p "$CLIENT_DIR"
CLIENT_DIR="$(cd "$CLIENT_DIR" && pwd)"
echo "Syncing user home template:"
echo "  from: $USER_HOME_TEMPLATE_DIR"
echo "  to:   $CLIENT_DIR"
echo "  mode: template files are refreshed; local-only files are kept"
tar -C "$USER_HOME_TEMPLATE_DIR" \
  --exclude='./client.env' \
  --exclude='./.config/pulse' \
  --exclude='./*.log' \
  --exclude='./*.mp3' \
  --exclude='./*.bak' \
  -cf - . | tar -C "$CLIENT_DIR" -xf -

volume_args=()
if [ "$CLIENT_MOUNT" = "/home/${RDP_USER}" ]; then
  client_owner_uid="$(stat -c '%u' "$CLIENT_DIR")"
  if [ "$client_owner_uid" != "$CONTAINER_USER_UID" ]; then
    if [ "$FIX_HOME_OWNERSHIP" = 1 ]; then
      echo "Fixing ownership of $CLIENT_DIR to $CONTAINER_USER_UID:$CONTAINER_USER_GID..."
      chown -R "$CONTAINER_USER_UID:$CONTAINER_USER_GID" "$CLIENT_DIR"
    else
      echo "Warning: $CLIENT_DIR is UID $client_owner_uid; XRDP user is UID $CONTAINER_USER_UID." >&2
      echo "         Home ownership auto-fix is disabled by FIX_HOME_OWNERSHIP=0." >&2
    fi
  fi
fi
volume_args+=(--volume "${CLIENT_DIR}:${CLIENT_MOUNT}:rw")

print_target() {
  local ip_addr mac_addr
  ip_addr="$("$PODMAN" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  mac_addr="$("$PODMAN" inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  echo
  [ -n "$mac_addr" ] && echo "Router DHCP reservation MAC: $mac_addr"
  if [ -n "$ip_addr" ]; then
    echo "Connect RDP client to: ${ip_addr}:3389"
  else
    echo "DHCP IP not visible yet. Check with:"
    echo "  sudo $PODMAN inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME"
  fi
}

echo "Image:      $IMAGE_NAME"
echo "Container:  $CONTAINER_NAME"
echo "Hostname:   $CONTAINER_HOSTNAME"
echo "Build file: $BUILD_FILE"
echo "Network:    $NETWORK_NAME (macvlan DHCP on $PARENT_IFACE)"
echo "MAC:        $CONTAINER_MAC"
echo "Home tpl:   ${USER_HOME_TEMPLATE_DIR:-none}"
echo "Home volume:${CLIENT_DIR:-none}"
echo "Mount path: $CLIENT_MOUNT"

image_rebuilt=0
if [ "$REBUILD" = 1 ] || ! podman_exists image "$IMAGE_NAME"; then
  echo "Building image..."
  "$PODMAN" build --network host --build-arg "RDP_USER=$RDP_USER" -t "$IMAGE_NAME" -f "$BUILD_FILE" "$BUILD_CONTEXT"
  image_rebuilt=1
else
  echo "Image already exists. Set REBUILD=1 to rebuild."
fi

if podman_exists network "$NETWORK_NAME"; then
  echo "Network already exists: $NETWORK_NAME"
else
  echo "Creating macvlan DHCP network on $PARENT_IFACE..."
  "$PODMAN" network create \
    -d macvlan \
    -o parent="$PARENT_IFACE" \
    --ipam-driver dhcp \
    "$NETWORK_NAME"
fi

create_container() {
  echo "Creating and starting container..."
  "$PODMAN" run \
    -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_HOSTNAME" \
    --network "$NETWORK_NAME" \
    --mac-address "$CONTAINER_MAC" \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --env RDP_USER \
    --env RDP_PASSWORD \
    "${volume_args[@]}" \
    "$IMAGE_NAME"
  print_target
}

if podman_exists container "$CONTAINER_NAME"; then
  current_mac="$("$PODMAN" inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [ -n "$current_mac" ] && [ "$current_mac" != "$CONTAINER_MAC" ]; then
    echo "Existing container MAC is $current_mac; recreating with $CONTAINER_MAC..."
    RECREATE=1
  fi

  current_hostname="$("$PODMAN" inspect -f '{{.Config.Hostname}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [ -n "$current_hostname" ] && [ "$current_hostname" != "$CONTAINER_HOSTNAME" ]; then
    echo "Existing container hostname is $current_hostname; recreating with $CONTAINER_HOSTNAME..."
    RECREATE=1
  fi

  if [ "$RECREATE" = 1 ] || [ "$image_rebuilt" = 1 ]; then
    echo "Removing existing container..."
    "$PODMAN" rm -f "$CONTAINER_NAME"
    create_container
  elif [ "$("$PODMAN" inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" = true ]; then
    echo "Restarting existing container to apply synced home template..."
    "$PODMAN" restart "$CONTAINER_NAME"
    print_target
  else
    echo "Starting existing container..."
    "$PODMAN" start "$CONTAINER_NAME"
    print_target
  fi
else
  create_container
fi

echo
echo "Login: $RDP_USER / RDP_PASSWORD from $ENV_FILE"
echo "Inside desktop: cd ~ && ./vpn.sh && ./rdp.sh"
echo "Logs: sudo $PODMAN logs -f $CONTAINER_NAME"
