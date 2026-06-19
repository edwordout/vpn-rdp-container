print_target() {
  local ip_addr mac_addr
  ip_addr="$("$PODMAN" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  mac_addr="$("$PODMAN" inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  echo
  [ -n "$mac_addr" ] && echo "Router DHCP reservation MAC: $mac_addr"
  if [ -n "$ip_addr" ]; then
    if [ "$RDP_ACCESS_MODE" = ssh-tunnel ]; then
      write_ssh_config_entry "$ip_addr"
      echo "Open SSH tunnel:"
      echo "  ssh -fN vpn-rdp-container"
      echo "Stop SSH tunnel:"
      echo "  ssh -O exit vpn-rdp-container"
      echo "Then connect RDP client to: localhost:3389"
    else
      echo "Connect RDP client to: ${ip_addr}:3389"
    fi
  else
    echo "DHCP IP not visible yet. Check with:"
    echo "  sudo $PODMAN inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME"
  fi
}

print_summary() {
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
}

image_env_value() {
  local env_name="$1" env_lines
  env_lines="$("$PODMAN" image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE_NAME" 2>/dev/null || true)"
  printf '%s\n' "$env_lines" | awk -F= -v env_name="$env_name" '$1 == env_name {sub(/^[^=]*=/, ""); print; exit}'
}

build_image() {
  local image_exists image_gid image_uid should_build
  local -a build_cache_args=()
  image_rebuilt=0
  image_exists=0
  should_build=0

  if podman_exists image "$IMAGE_NAME"; then
    image_exists=1
    image_uid="$(image_env_value CONTAINER_USER_UID)"
    image_gid="$(image_env_value CONTAINER_USER_GID)"
  fi

  if [ "$REBUILD" = 1 ]; then
    echo "Building image..."
    should_build=1
    if [ "$image_exists" = 1 ] \
      && { [ -z "$image_uid" ] || [ -z "$image_gid" ] \
        || [ "$image_uid" != "$CONTAINER_USER_UID" ] \
        || [ "$image_gid" != "$CONTAINER_USER_GID" ]; }; then
      build_cache_args+=(--no-cache)
    fi
  elif [ "$image_exists" != 1 ]; then
    echo "Building image..."
    should_build=1
  elif [ -z "$image_uid" ] || [ -z "$image_gid" ] \
    || [ "$image_uid" != "$CONTAINER_USER_UID" ] \
    || [ "$image_gid" != "$CONTAINER_USER_GID" ]; then
    echo "Existing image user IDs differ; rebuilding for CONTAINER_USER_UID=$CONTAINER_USER_UID CONTAINER_USER_GID=$CONTAINER_USER_GID..."
    build_cache_args+=(--no-cache)
    should_build=1
  else
    echo "Image already exists. Set REBUILD=1 to rebuild."
  fi

  if [ "$should_build" = 1 ]; then
    "$PODMAN" build \
      "${build_cache_args[@]}" \
      --network host \
      --build-arg "RDP_USER=$RDP_USER" \
      --build-arg "CONTAINER_USER_UID=$CONTAINER_USER_UID" \
      --build-arg "CONTAINER_USER_GID=$CONTAINER_USER_GID" \
      -t "$IMAGE_NAME" \
      -f "$BUILD_FILE" \
      "$BUILD_CONTEXT"
    image_rebuilt=1
  fi
}

ensure_network() {
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
}

create_container() {
  echo "Creating and starting container..."
  "$PODMAN" run \
    -d \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_HOSTNAME" \
    --network "$NETWORK_NAME" \
    --mac-address "$CONTAINER_MAC" \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
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

reconcile_container() {
  local current_mac current_hostname

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
}
