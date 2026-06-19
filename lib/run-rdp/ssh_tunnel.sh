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

write_ssh_config_entry() {
  local ip_addr="$1"
  local ssh_dir="$HOST_HOME/.ssh"
  local root_config="$ssh_dir/config"
  local include_dir="$ssh_dir/config.d"
  local managed_config="$include_dir/vpn-rdp-container"
  local include_line='Include ~/.ssh/config.d/*'

  [ -n "$ip_addr" ] || fail "SSH config HostName is empty."

  mkdir -p "$ssh_dir" "$include_dir"
  chmod 700 "$ssh_dir" "$include_dir"
  touch "$root_config"

  if ! grep -Fxq "$include_line" "$root_config"; then
    {
      printf '\n'
      printf '%s\n' "$include_line"
    } >> "$root_config"
  fi

  cat > "$managed_config" <<EOF
# Managed by vpn-rdp-container. Re-run ./run-rdp-container.sh after DHCP changes.
Host vpn-rdp-container
  HostName $ip_addr
  User $RDP_USER
  Port $SSH_PORT
  IdentityFile $SSH_KEY_FILE
  IdentitiesOnly yes
  LocalForward 127.0.0.1:3389 127.0.0.1:3389
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ControlMaster auto
  ControlPath ~/.ssh/cm-vpn-rdp-container
  ControlPersist yes
EOF

  chmod 600 "$root_config" "$managed_config"
  chown "$HOST_UID:$HOST_GID" "$ssh_dir" "$root_config" "$include_dir" "$managed_config"
  echo "Wrote SSH config entry: $managed_config"
}
