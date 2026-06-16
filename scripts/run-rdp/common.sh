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
