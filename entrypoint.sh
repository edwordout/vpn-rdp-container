#!/bin/sh
set -eu

: "${RDP_USER:?RDP_USER is required; set it in run-rdp-container.env or build with --build-arg RDP_USER}"
: "${RDP_PASSWORD:?RDP_PASSWORD is required; set it in run-rdp-container.env or pass it to podman}"

if getent passwd "$RDP_USER" >/dev/null 2>&1; then
  printf '%s:%s\n' "$RDP_USER" "$RDP_PASSWORD" | chpasswd
  user_home="$(getent passwd "$RDP_USER" | cut -d: -f6)"
  user_uid="$(getent passwd "$RDP_USER" | cut -d: -f3)"
  user_gid="$(getent passwd "$RDP_USER" | cut -d: -f4)"
  mkdir -p "/run/user/$user_uid"
  chown "$user_uid:$user_gid" "/run/user/$user_uid"
  chmod 700 "/run/user/$user_uid"
  rm -f "$user_home/.Xauthority"
else
  echo "Error: RDP user does not exist: $RDP_USER" >&2
  exit 1
fi

mkdir -p /run/xrdp /run/xrdp/sockdir /var/run/xrdp /var/log/xrdp /tmp/.X11-unix
chmod 1777 /tmp /tmp/.X11-unix
rm -f /run/xrdp/*.pid /var/run/xrdp/*.pid || true

start_rdp_return_route_guard() {
  lan_dev="$(ip -4 route show default | awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  lan_gw="$(ip -4 route show default | awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}')"

  [ -n "$lan_dev" ] || return 0

  (
    seen_clients=""
    while :; do
      rdp_clients="$(ss -tnH sport = :3389 2>/dev/null \
        | awk '{print $5}' \
        | sed -E 's/^\[?([^]]+)\]?:[0-9]+$/\1/; s/^::ffff://')"
      for rdp_client in $rdp_clients; do
        [ -n "$rdp_client" ] || continue
        case " $seen_clients " in *" $rdp_client "*) continue ;; esac
        if [ -n "$lan_gw" ]; then
          ip route replace "${rdp_client}/32" via "$lan_gw" dev "$lan_dev" || true
        else
          ip route replace "${rdp_client}/32" dev "$lan_dev" || true
        fi
        seen_clients="$seen_clients $rdp_client"
        echo "Pinned XRDP return route for $rdp_client via ${lan_gw:-direct} dev $lan_dev"
      done
      sleep 2
    done
  ) &
}

start_rdp_return_route_guard

/usr/sbin/xrdp-sesman --nodaemon &

exec /usr/sbin/xrdp --nodaemon
