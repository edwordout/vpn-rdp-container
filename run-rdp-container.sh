#!/usr/bin/env bash

# Entrypoint layout:
# - keep top level definition-only so tests can safely source this file;
# - put config/default loading in helpers;
# - keep container side effects in main.
setup_logging() {
  LOG_FILE="${SCRIPT_DIR}/run-rdp-container.log"
  exec > >(tee "$LOG_FILE") 2>&1
}

load_env_config() {
  : "${ENV_FILE:=${SCRIPT_DIR}/run-rdp-container.env}"

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
}

load_modules() {
  local module
  local -a modules=(
    common
    preflight
    home
    ssh_tunnel
    podman
  )

  for module in "${modules[@]}"; do
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/run-rdp/${module}.sh"
  done
}

load_host_identity() {
  HOST_USER="$(host_user_name)"
  HOST_UID="$(host_user_field "$HOST_USER" 3 || true)"
  HOST_GID="$(host_user_field "$HOST_USER" 4 || true)"
  HOST_HOME="$(host_user_field "$HOST_USER" 6 || true)"

  if [ -z "$HOST_UID" ] || [ -z "$HOST_GID" ] || [ -z "$HOST_HOME" ]; then
    fail "Could not infer host user UID, GID, and home for $HOST_USER."
  fi
  if [ "$HOST_UID" = 0 ]; then
    fail "Could not infer a non-root host user. Run this script with sudo from the host account that should own the shared home."
  fi
}

apply_defaults() {
  # App / image identity
  : "${APP_NAME:=vpn-rdp}"
  : "${IMAGE_TAG:=stable}"
  : "${IMAGE_NAME:=${APP_NAME}:${IMAGE_TAG}}"
  : "${CONTAINER_NAME:=${APP_NAME}}"
  : "${CONTAINER_HOSTNAME:=${APP_NAME}}"

  # Build configuration
  : "${BUILD_CONTEXT:=${SCRIPT_DIR}}"
  BUILD_CONTEXT="$(cd -- "$BUILD_CONTEXT" && pwd -P)" || {
    echo "Invalid BUILD_CONTEXT: $BUILD_CONTEXT" >&2
    exit 1
  }
  : "${BUILD_FILE:=}"

  # Runtime behavior
  : "${PODMAN:=podman}"
  : "${REBUILD:=0}"
  : "${RECREATE:=0}"

  # Networking
  : "${PARENT_IFACE:=}"
  : "${CONTAINER_MAC:=}"
  : "${NETWORK_NAME:=}"
  : "${RDP_ACCESS_MODE:=direct}"
  : "${CONTAINER_FIREWALL:=1}"

  # SSH
  : "${SSH_PORT:=2022}"
  : "${SSH_KEY_FILE:=}"
  : "${SSH_PUBLIC_KEY_FILE:=}"
  : "${SSH_HOST_KEYS_DIR:=${BUILD_CONTEXT}/ssh_host_keys}"

  # User home / volume
  : "${USER_HOME_TEMPLATE_DIR:=${BUILD_CONTEXT}/user_home_template}"
  : "${CLIENT_DIR:=${BUILD_CONTEXT}/user_home_volume}"
  : "${FIX_HOME_OWNERSHIP:=1}"

  # Build-time container user identity. Defaults to the sudo-invoking host user.
  : "${CONTAINER_USER_UID:=$HOST_UID}"
  : "${CONTAINER_USER_GID:=$HOST_GID}"
}

run_orchestration() {
  run_preflight
  sync_user_home_template
  prepare_ssh_tunnel
  prepare_volume_args
  print_summary
  build_image
  ensure_network
  reconcile_container

  echo
  echo "Login: $RDP_USER / RDP_PASSWORD from $ENV_FILE"
  echo "Inside desktop: cd ~ && ./vpn.sh && ./rdp.sh"
  echo "Logs: sudo $PODMAN logs -f $CONTAINER_NAME"
}

main() {
  set -euo pipefail
  trap 'echo "Error: run-rdp-container.sh failed near line $LINENO: $BASH_COMMAND" >&2' ERR

  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  setup_logging
  load_env_config
  load_modules
  load_host_identity
  apply_defaults
  run_orchestration
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
