sync_user_home_template() {
  [ -d "$USER_HOME_TEMPLATE_DIR" ] || fail "user home template not found: $USER_HOME_TEMPLATE_DIR"
  USER_HOME_TEMPLATE_DIR="$(cd "$USER_HOME_TEMPLATE_DIR" && pwd)"
  mkdir -p "$CLIENT_DIR"
  CLIENT_DIR="$(cd "$CLIENT_DIR" && pwd)"
  echo "Syncing user home template:"
  echo "  from: $USER_HOME_TEMPLATE_DIR"
  echo "  to:   $CLIENT_DIR"
  echo "  mode: template files are refreshed; local-only files are kept"
  chown -R "$HOST_UID:$HOST_GID" "$USER_HOME_TEMPLATE_DIR"
  chmod -R u+rwX "$USER_HOME_TEMPLATE_DIR"
  if [ "$FIX_HOME_OWNERSHIP" = 1 ]; then
    echo "Fixing ownership of $CLIENT_DIR to $CONTAINER_USER_UID:$CONTAINER_USER_GID..."
    chown -R "$CONTAINER_USER_UID:$CONTAINER_USER_GID" "$CLIENT_DIR"
    chmod -R u+rwX "$CLIENT_DIR"
  fi
  tar -C "$USER_HOME_TEMPLATE_DIR" \
    --exclude='./client.env' \
    --exclude='./.config/pulse' \
    --exclude='./*.log' \
    --exclude='./*.mp3' \
    --exclude='./*.bak' \
    -cf - . | tar -C "$CLIENT_DIR" -xf -
}

prepare_volume_args() {
  local client_owner expected_owner ssh_owner

  volume_args=()
  if [ "$CLIENT_MOUNT" = "/home/${RDP_USER}" ] && [ "$FIX_HOME_OWNERSHIP" = 0 ]; then
    expected_owner="$CONTAINER_USER_UID:$CONTAINER_USER_GID"
    client_owner="$(stat -c '%u:%g' "$CLIENT_DIR")"
    ssh_owner="$expected_owner"
    [ ! -e "$CLIENT_DIR/.ssh" ] || ssh_owner="$(stat -c '%u:%g' "$CLIENT_DIR/.ssh")"
    if [ "$client_owner" != "$expected_owner" ] || [ "$ssh_owner" != "$expected_owner" ]; then
      fail "FIX_HOME_OWNERSHIP=0 but $CLIENT_DIR ownership is not $CONTAINER_USER_UID:$CONTAINER_USER_GID; host/container shared home access is not guaranteed."
    fi
  fi
  volume_args+=(--volume "${CLIENT_DIR}:${CLIENT_MOUNT}:rw")
  if [ "$RDP_ACCESS_MODE" = ssh-tunnel ]; then
    volume_args+=(--volume "${SSH_HOST_KEYS_DIR}:/etc/ssh/host_keys:ro")
  fi
}
