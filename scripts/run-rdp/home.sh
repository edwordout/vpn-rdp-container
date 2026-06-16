sync_user_home_template() {
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
}

prepare_volume_args() {
  local client_owner_uid ssh_owner_uid

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
}
