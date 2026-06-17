require_config() {
  local config_name="$1"
  [ -n "${!config_name:-}" ] || fail "$config_name is not set in $ENV_FILE"
}

require_numeric_config() {
  local config_name="$1"
  local config_value="${!config_name:-}"
  [[ "$config_value" =~ ^[0-9]+$ ]] || fail "$config_name must be numeric, got: $config_value"
}

validate_config() {
  local required_configs=(
    RDP_USER
    RDP_PASSWORD
    CONTAINER_HOSTNAME
    PARENT_IFACE
    CONTAINER_MAC
  )
  local config_name

  for config_name in "${required_configs[@]}"; do
    require_config "$config_name"
  done

  [[ "$CONTAINER_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || fail "CONTAINER_MAC is invalid: $CONTAINER_MAC"

  case "$RDP_ACCESS_MODE" in
    direct|ssh-tunnel) ;;
    *) fail "RDP_ACCESS_MODE must be direct or ssh-tunnel, got: $RDP_ACCESS_MODE" ;;
  esac

  require_numeric_config SSH_PORT
  [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || fail "SSH_PORT must be between 1 and 65535, got: $SSH_PORT"

  require_numeric_config CONTAINER_USER_UID
  require_numeric_config CONTAINER_USER_GID
  [ "$CONTAINER_USER_UID" -ge 1 ] || fail "CONTAINER_USER_UID must be greater than zero, got: $CONTAINER_USER_UID"
  [ "$CONTAINER_USER_GID" -ge 1 ] || fail "CONTAINER_USER_GID must be greater than zero, got: $CONTAINER_USER_GID"

  : "${NETWORK_NAME:=${APP_NAME}_macvlan_dhcp_${PARENT_IFACE}}"
  : "${CLIENT_MOUNT:=/home/${RDP_USER}}"
  if [ "$CLIENT_MOUNT" = "/home/${RDP_USER}" ] \
    && { [ "$CONTAINER_USER_UID" != "$HOST_UID" ] || [ "$CONTAINER_USER_GID" != "$HOST_GID" ]; }; then
    fail "CONTAINER_USER_UID/CONTAINER_USER_GID must match host user $HOST_USER ($HOST_UID:$HOST_GID) when CLIENT_MOUNT is /home/$RDP_USER; rebuild with matching IDs or set CLIENT_MOUNT to a non-home path."
  fi
}

check_host_prerequisites() {
  [ "$(id -u)" = 0 ] || fail "macvlan-dhcp requires rootful Podman. Run: sudo ./run-rdp-container.sh"
  command -v "$PODMAN" >/dev/null 2>&1 || fail "podman is not installed or not in PATH."
  command -v ip >/dev/null 2>&1 || fail "iproute2 is required."
  if [ "$RDP_ACCESS_MODE" = ssh-tunnel ]; then
    command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is required for RDP_ACCESS_MODE=ssh-tunnel."
  fi
  ip link show "$PARENT_IFACE" >/dev/null 2>&1 || fail "host interface not found: $PARENT_IFACE"
}

prepare_tun_device() {
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
}

enable_netavark_dhcp_proxy() {
  command -v systemctl >/dev/null 2>&1 || fail "systemctl is required to enable netavark DHCP proxy."
  [ -d /run/systemd/system ] || fail "systemd is not running; cannot enable netavark DHCP proxy."
  if ! systemctl is-active --quiet netavark-dhcp-proxy.socket; then
    echo "Enabling netavark DHCP proxy..."
    systemctl enable --now netavark-dhcp-proxy.socket \
      || fail "could not enable netavark-dhcp-proxy.socket"
  fi
}

resolve_build_file() {
  if [ -z "$BUILD_FILE" ]; then
    if [ -f "$BUILD_CONTEXT/Containerfile" ]; then
      BUILD_FILE="$BUILD_CONTEXT/Containerfile"
    elif [ -f "$BUILD_CONTEXT/Dockerfile" ]; then
      BUILD_FILE="$BUILD_CONTEXT/Dockerfile"
    else
      fail "no Containerfile or Dockerfile found in $BUILD_CONTEXT"
    fi
  fi
}

run_preflight() {
  validate_config
  check_host_prerequisites
  prepare_tun_device
  enable_netavark_dhcp_proxy
  resolve_build_file
}
