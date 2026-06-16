prepare_ssh_tunnel() {
  [ "$RDP_ACCESS_MODE" = ssh-tunnel ] || return 0

  local host_user host_uid host_gid host_home ssh_public_key restricted_key_line
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

  generate_ssh_host_key ed25519 "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key"
  generate_ssh_host_key ecdsa "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" -b 256
  generate_ssh_host_key rsa "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" -b 3072
}

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
    cat <<'HELPER_EOF'
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
HELPER_EOF
  } > "$helper_path"

  chmod +x "$helper_path"
  host_user="$(host_user_name)"
  host_uid="$(host_user_field "$host_user" 3)"
  host_gid="$(host_user_field "$host_user" 4)"
  [ -z "$host_uid" ] || chown "$host_uid:$host_gid" "$helper_path"
  echo "Wrote SSH tunnel helper: $helper_path"
}
