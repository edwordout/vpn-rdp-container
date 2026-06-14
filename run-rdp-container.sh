#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error: run-rdp-container.sh failed near line $LINENO: $BASH_COMMAND" >&2' ERR

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
RDP_ACCESS_MODE="${RDP_ACCESS_MODE:-direct}"
CONTAINER_FIREWALL="${CONTAINER_FIREWALL:-1}"
SSH_PORT="${SSH_PORT:-2022}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
SSH_HOST_KEYS_DIR="${SSH_HOST_KEYS_DIR:-$BUILD_CONTEXT/ssh_host_keys}"

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

host_user_name() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

host_user_field() {
  local user_name="$1"
  local field="$2"
  getent passwd "$user_name" | cut -d: -f"$field"
}

expand_host_path() {
  local path="$1"
  local home_dir="$2"
  case "$path" in
    "~") printf '%s\n' "$home_dir" ;;
    "~/"*) printf '%s/%s\n' "$home_dir" "${path#~/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

[ -n "${RDP_USER:-}" ] || fail "RDP_USER is not set in $ENV_FILE"
[ -n "${RDP_PASSWORD:-}" ] || fail "RDP_PASSWORD is not set in $ENV_FILE"
[ -n "$CONTAINER_HOSTNAME" ] || fail "CONTAINER_HOSTNAME is empty in $ENV_FILE"
[ -n "$PARENT_IFACE" ] || fail "PARENT_IFACE is not set in $ENV_FILE"
[ -n "$CONTAINER_MAC" ] || fail "CONTAINER_MAC is not set in $ENV_FILE"
[[ "$CONTAINER_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || fail "CONTAINER_MAC is invalid: $CONTAINER_MAC"
case "$RDP_ACCESS_MODE" in
  direct|ssh-tunnel) ;;
  *) fail "RDP_ACCESS_MODE must be direct or ssh-tunnel, got: $RDP_ACCESS_MODE" ;;
esac
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || fail "SSH_PORT must be numeric, got: $SSH_PORT"
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || fail "SSH_PORT must be between 1 and 65535, got: $SSH_PORT"
NETWORK_NAME="${NETWORK_NAME:-${APP_NAME}_macvlan_dhcp_${PARENT_IFACE}}"
CLIENT_MOUNT="${CLIENT_MOUNT:-/home/${RDP_USER}}"

[ "$(id -u)" = 0 ] || fail "macvlan-dhcp requires rootful Podman. Run: sudo ./run-rdp-container.sh"
command -v "$PODMAN" >/dev/null 2>&1 || fail "podman is not installed or not in PATH."
command -v ip >/dev/null 2>&1 || fail "iproute2 is required."
if [ "$RDP_ACCESS_MODE" = ssh-tunnel ]; then
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required for RDP_ACCESS_MODE=ssh-tunnel."
fi
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

if [ "$RDP_ACCESS_MODE" = ssh-tunnel ]; then
  host_user="$(host_user_name)"
  host_uid="$(host_user_field "$host_user" 3)"
  host_gid="$(host_user_field "$host_user" 4)"
  host_home="$(host_user_field "$host_user" 6)"
  [ -n "$host_home" ] || fail "could not resolve home directory for $host_user"

  if [ -z "$SSH_KEY_FILE" ] && [ -n "$SSH_PUBLIC_KEY_FILE" ]; then
    case "$SSH_PUBLIC_KEY_FILE" in
      *.pub) SSH_KEY_FILE="${SSH_PUBLIC_KEY_FILE%.pub}" ;;
      *) fail "SSH_PUBLIC_KEY_FILE requires SSH_KEY_FILE unless it ends with .pub" ;;
    esac
  fi

  SSH_KEY_FILE="$(expand_host_path "${SSH_KEY_FILE:-$host_home/.ssh/vpn-rdp-container_ed25519}" "$host_home")"
  SSH_PUBLIC_KEY_FILE="$(expand_host_path "${SSH_PUBLIC_KEY_FILE:-${SSH_KEY_FILE}.pub}" "$host_home")"

  mkdir -p "$(dirname "$SSH_KEY_FILE")"
  chown "$host_uid:$host_gid" "$(dirname "$SSH_KEY_FILE")"
  chmod 700 "$(dirname "$SSH_KEY_FILE")"

  if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Generating SSH tunnel key: $SSH_KEY_FILE"
    ssh-keygen -t ed25519 -N "" -C "vpn-rdp-container" -f "$SSH_KEY_FILE"
    chown "$host_uid:$host_gid" "$SSH_KEY_FILE" "${SSH_KEY_FILE}.pub"
    chmod 600 "$SSH_KEY_FILE"
    chmod 644 "${SSH_KEY_FILE}.pub"
  fi

  if [ ! -f "$SSH_PUBLIC_KEY_FILE" ]; then
    echo "Writing SSH public key: $SSH_PUBLIC_KEY_FILE"
    ssh-keygen -y -P "" -f "$SSH_KEY_FILE" > "$SSH_PUBLIC_KEY_FILE"
    chown "$host_uid:$host_gid" "$SSH_PUBLIC_KEY_FILE"
    chmod 644 "$SSH_PUBLIC_KEY_FILE"
  fi

  [ -f "$SSH_KEY_FILE" ] || fail "SSH_KEY_FILE does not exist: $SSH_KEY_FILE"
  [ -f "$SSH_PUBLIC_KEY_FILE" ] || fail "SSH_PUBLIC_KEY_FILE does not exist: $SSH_PUBLIC_KEY_FILE"

  ssh_public_key="$(awk 'NF && $1 !~ /^#/ {print; exit}' "$SSH_PUBLIC_KEY_FILE" | tr -d '\r\n')"
  [ -n "$ssh_public_key" ] || fail "SSH public key is empty: $SSH_PUBLIC_KEY_FILE"
  restricted_key_line="restrict,port-forwarding,permitopen=\"127.0.0.1:3389\" $ssh_public_key"

  mkdir -p "$CLIENT_DIR/.ssh"
  touch "$CLIENT_DIR/.ssh/authorized_keys"
  chmod 700 "$CLIENT_DIR/.ssh"
  chmod 600 "$CLIENT_DIR/.ssh/authorized_keys"
  if ! grep -Fxq "$restricted_key_line" "$CLIENT_DIR/.ssh/authorized_keys"; then
    printf '%s\n' "$restricted_key_line" >> "$CLIENT_DIR/.ssh/authorized_keys"
    echo "Added restricted SSH tunnel key to $CLIENT_DIR/.ssh/authorized_keys"
  else
    echo "Restricted SSH tunnel key already present in $CLIENT_DIR/.ssh/authorized_keys"
  fi
  chown -R "$CONTAINER_USER_UID:$CONTAINER_USER_GID" "$CLIENT_DIR/.ssh"

  SSH_HOST_KEYS_DIR="$(expand_host_path "$SSH_HOST_KEYS_DIR" "$host_home")"
  case "$SSH_HOST_KEYS_DIR" in
    /*) ;;
    *) SSH_HOST_KEYS_DIR="$SCRIPT_DIR/$SSH_HOST_KEYS_DIR" ;;
  esac
  mkdir -p "$SSH_HOST_KEYS_DIR"
  chmod 700 "$SSH_HOST_KEYS_DIR"
  chown root:root "$SSH_HOST_KEYS_DIR"

  generate_ssh_host_key() {
    local key_type="$1"
    local key_path="$2"
    shift 2

    if [ ! -f "$key_path" ]; then
      echo "Generating persistent SSH host key: $key_path"
      ssh-keygen -t "$key_type" "$@" -N "" -f "$key_path" >/dev/null
    fi
    [ -f "$key_path" ] || fail "SSH host key missing: $key_path"
    [ -f "${key_path}.pub" ] || ssh-keygen -y -f "$key_path" > "${key_path}.pub"
    chown root:root "$key_path" "${key_path}.pub"
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
  }

  generate_ssh_host_key ed25519 "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key"
  generate_ssh_host_key ecdsa "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" -b 256
  generate_ssh_host_key rsa "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" -b 3072
fi

volume_args=()
if [ "$CLIENT_MOUNT" = "/home/${RDP_USER}" ]; then
  client_owner_uid="$(stat -c '%u' "$CLIENT_DIR")"
  ssh_owner_uid="$CONTAINER_USER_UID"
  [ ! -e "$CLIENT_DIR/.ssh" ] || ssh_owner_uid="$(stat -c '%u' "$CLIENT_DIR/.ssh")"
  if [ "$client_owner_uid" != "$CONTAINER_USER_UID" ] || [ "$ssh_owner_uid" != "$CONTAINER_USER_UID" ]; then
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
if [ "$RDP_ACCESS_MODE" = ssh-tunnel ]; then
  volume_args+=(--volume "${SSH_HOST_KEYS_DIR}:/etc/ssh/host_keys:ro")
fi

print_target() {
  local ip_addr mac_addr
  ip_addr="$("$PODMAN" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  mac_addr="$("$PODMAN" inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  echo
  [ -n "$mac_addr" ] && echo "Router DHCP reservation MAC: $mac_addr"
  if [ -n "$ip_addr" ]; then
    if [ "$RDP_ACCESS_MODE" = ssh-tunnel ]; then
      write_ssh_tunnel_helper "$ip_addr"
      echo "Open SSH tunnel:"
      echo "  ssh -i \"$SSH_KEY_FILE\" -p \"$SSH_PORT\" -N -L 3389:127.0.0.1:3389 \"$RDP_USER@$ip_addr\""
      echo "Or run:"
      echo "  ./start_ssh_tunnel.sh"
      echo "Then connect RDP client to: localhost:3389"
    else
      echo "Connect RDP client to: ${ip_addr}:3389"
    fi
  else
    echo "DHCP IP not visible yet. Check with:"
    echo "  sudo $PODMAN inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME"
  fi
}

write_ssh_tunnel_helper() {
  local ip_addr="$1"
  local helper_path="$SCRIPT_DIR/start_ssh_tunnel.sh"
  local host_user host_uid host_gid existing_ip

  if [ -e "$helper_path" ]; then
    existing_ip="$(sed -nE 's/^[[:space:]]*container_ip=(.*)$/\1/p' "$helper_path" | head -n1)"
    existing_ip="${existing_ip%\"}"
    existing_ip="${existing_ip#\"}"
    existing_ip="${existing_ip%\'}"
    existing_ip="${existing_ip#\'}"
    if [ -z "$existing_ip" ]; then
      echo "Warning: existing SSH tunnel helper has no readable container_ip: $helper_path" >&2
      echo "         Not overwriting it. Edit it or remove it to regenerate." >&2
    elif [ "$existing_ip" != "$ip_addr" ]; then
      echo "Warning: existing SSH tunnel helper uses container_ip=$existing_ip, but current container IP is $ip_addr." >&2
      echo "         Not overwriting it. Edit $helper_path or remove it to regenerate." >&2
    else
      echo "SSH tunnel helper already exists; leaving unchanged: $helper_path"
    fi
    return 0
  fi

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '\n'
    printf 'container_ip=%q\n' "$ip_addr"
    printf 'container_name=%q\n' "$CONTAINER_NAME"
    printf 'ssh_user=%q\n' "$RDP_USER"
    printf 'ssh_port=%q\n' "$SSH_PORT"
    printf 'ssh_key_default=%q\n' "$SSH_KEY_FILE"
    cat <<'EOF'
ssh_key="${SSH_KEY_FILE:-$ssh_key_default}"
local_port="${LOCAL_RDP_PORT:-3389}"
remote_rdp="127.0.0.1:3389"
attach="${SSH_TUNNEL_ATTACH:-0}"
mode="start"
control_dir="${XDG_RUNTIME_DIR:-/tmp}/vpn-rdp-container-ssh"
control_path="${SSH_TUNNEL_CONTROL_PATH:-$control_dir/${container_name}-${local_port}.sock}"
local_forward="127.0.0.1:${local_port}:${remote_rdp}"
ssh_target="${ssh_user}@${container_ip}"

usage() {
  cat <<HELP_EOF
Usage:
  $0 [--background|--attach|--stop]

Options:
  -b, --background   Start the SSH tunnel in the background (default).
  -a, --attach       Keep SSH attached in this terminal; Ctrl+C stops it.
      --stop         Stop the background tunnel for localhost:${local_port}.
  -h, --help         Show this help.

Environment overrides:
  LOCAL_RDP_PORT=3390          Local RDP listen port. Default: 3389.
  SSH_KEY_FILE=/path/to/key    Private key to use for the tunnel.
  SSH_TUNNEL_ATTACH=1          Same as --attach.
  SSH_TUNNEL_CONTROL_PATH=...  SSH control socket path override.

Current tunnel target:
  localhost:${local_port} -> ${container_ip}:${remote_rdp}
  SSH target: ${ssh_user}@${container_ip}:${ssh_port}
HELP_EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -a|--attach)
      attach=1
      ;;
    -b|--background)
      attach=0
      ;;
    --stop)
      mode="stop"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$attach" in
  1|true|yes|on) attach=1 ;;
  0|false|no|off|"") attach=0 ;;
  *)
    echo "Error: SSH_TUNNEL_ATTACH must be 0/1, true/false, yes/no, or on/off." >&2
    exit 2
    ;;
esac

stop_tunnel() {
  local pids

  if [ -S "$control_path" ]; then
    if ssh -S "$control_path" -O exit -p "$ssh_port" "$ssh_target" >/dev/null 2>&1; then
      echo "Stopped SSH tunnel via control socket: $control_path"
      exit 0
    fi
    rm -f "$control_path"
  fi

  pids="$(ps -u "$(id -u)" -o pid= -o args= \
    | awk -v local_forward="$local_forward" '$0 ~ /(^|[[:space:]])ssh[[:space:]]/ && index($0, local_forward) {print $1}')"
  if [ -z "$pids" ]; then
    echo "No matching SSH tunnel found for localhost:${local_port}."
    exit 0
  fi

  kill $pids
  echo "Stopped SSH tunnel process(es): $(echo "$pids" | xargs)"
}

if [ "$mode" = "stop" ]; then
  stop_tunnel
fi

if [ ! -r "$ssh_key" ]; then
  echo "Error: SSH key not readable: $ssh_key" >&2
  exit 1
fi

mkdir -p "$control_dir"
chmod 700 "$control_dir"
if [ -S "$control_path" ]; then
  if ssh -S "$control_path" -O check -p "$ssh_port" "$ssh_target" >/dev/null 2>&1; then
    echo "SSH tunnel already running for localhost:${local_port}."
    exit 0
  fi
  rm -f "$control_path"
fi

echo "Opening RDP tunnel: 127.0.0.1:${local_port} -> ${container_ip}:${remote_rdp}"
echo "Connect your RDP client to: localhost:${local_port}"

ssh_args=(
  -i "$ssh_key"
  -p "$ssh_port"
  -N
  -M
  -S "$control_path"
  -L "$local_forward"
  -o ExitOnForwardFailure=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  "$ssh_target"
)

if [ "$attach" = 1 ]; then
  echo "Mode: attached. Press Ctrl+C to stop the tunnel."
else
  echo "Mode: background. Use --attach or SSH_TUNNEL_ATTACH=1 to keep it attached."
  ssh_args=(-f "${ssh_args[@]}")
fi

if ssh "${ssh_args[@]}"; then
  [ "$attach" = 1 ] || echo "Tunnel started in background. Stop it with: $0 --stop"
  exit 0
else
  ssh_status=$?
fi

echo >&2
echo "Error: SSH tunnel failed with exit status $ssh_status." >&2
echo "       Target was ${ssh_user}@${container_ip}:${ssh_port}" >&2
echo "       If the container got a new DHCP IP, edit this file or remove it and rerun ./run-rdp-container.sh." >&2
echo "       Current container IP check:" >&2
echo "         sudo podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${container_name}" >&2
exit "$ssh_status"

EOF
  } > "$helper_path"

  chmod +x "$helper_path"
  host_user="$(host_user_name)"
  host_uid="$(host_user_field "$host_user" 3)"
  host_gid="$(host_user_field "$host_user" 4)"
  [ -z "$host_uid" ] || chown "$host_uid:$host_gid" "$helper_path"
  echo "Wrote SSH tunnel helper: $helper_path"
}

container_env_value() {
  local env_name="$1"
  local env_lines

  env_lines="$("$PODMAN" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  printf '%s\n' "$env_lines" \
    | awk -F= -v env_name="$env_name" '$1 == env_name {sub(/^[^=]*=/, ""); print; exit}'
}

mark_recreate_if_env_changed() {
  local env_name="$1"
  local current_value expected_value current_label expected_label
  current_value="$(container_env_value "$env_name")"
  expected_value="${!env_name:-}"
  if [ "$current_value" != "$expected_value" ]; then
    current_label="${current_value:-<unset>}"
    expected_label="${expected_value:-<unset>}"
    case "$env_name" in
      *PASSWORD*|*TOKEN*|*SECRET*|*KEY*) current_label="<redacted>"; expected_label="<redacted>" ;;
    esac
    echo "Existing container env $env_name differs ($current_label -> $expected_label); recreating..."
    RECREATE=1
  fi
}

container_has_mount_destination() {
  local destination="$1"
  local destinations
  destinations="$("$PODMAN" inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  printf '%s\n' "$destinations" | grep -Fxq "$destination"
}

echo "Image:      $IMAGE_NAME"
echo "Container:  $CONTAINER_NAME"
echo "Hostname:   $CONTAINER_HOSTNAME"
echo "Build file: $BUILD_FILE"
echo "Network:    $NETWORK_NAME (macvlan DHCP on $PARENT_IFACE)"
echo "MAC:        $CONTAINER_MAC"
echo "Access:     $RDP_ACCESS_MODE"
echo "Firewall:   $CONTAINER_FIREWALL"
[ "$RDP_ACCESS_MODE" = ssh-tunnel ] && echo "SSH port:   $SSH_PORT"
[ "$RDP_ACCESS_MODE" = ssh-tunnel ] && echo "SSH hosts:  $SSH_HOST_KEYS_DIR"
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
    --env "RDP_USER=$RDP_USER" \
    --env "RDP_PASSWORD=$RDP_PASSWORD" \
    --env "RDP_ACCESS_MODE=$RDP_ACCESS_MODE" \
    --env "CONTAINER_FIREWALL=$CONTAINER_FIREWALL" \
    --env "SSH_PORT=$SSH_PORT" \
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

  mark_recreate_if_env_changed RDP_USER
  mark_recreate_if_env_changed RDP_PASSWORD
  mark_recreate_if_env_changed RDP_ACCESS_MODE
  mark_recreate_if_env_changed CONTAINER_FIREWALL
  mark_recreate_if_env_changed SSH_PORT

  if [ "$RDP_ACCESS_MODE" = ssh-tunnel ] && ! container_has_mount_destination /etc/ssh/host_keys; then
    echo "Existing container is missing persistent SSH host keys mount; recreating..."
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
