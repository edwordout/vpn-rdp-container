#!/bin/sh
set -eu

: "${RDP_USER:?RDP_USER is required; set it in run-rdp-container.env or build with --build-arg RDP_USER}"
: "${RDP_PASSWORD:?RDP_PASSWORD is required; set it in run-rdp-container.env or pass it to podman}"

RDP_ACCESS_MODE="${RDP_ACCESS_MODE:-direct}"
CONTAINER_FIREWALL="${CONTAINER_FIREWALL:-1}"
SSH_PORT="${SSH_PORT:-2022}"
SSH_HOST_KEYS_DIR="/etc/ssh/host_keys"

case "$RDP_ACCESS_MODE" in
  direct)
    xrdp_port="3389"
    ingress_port="3389"
    ;;
  ssh-tunnel)
    xrdp_port="127.0.0.1:3389"
    ingress_port="$SSH_PORT"
    ;;
  *)
    echo "Error: unsupported RDP_ACCESS_MODE: $RDP_ACCESS_MODE" >&2
    exit 1
    ;;
esac

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

sed -i "0,/^port=/s|^port=.*|port=$xrdp_port|" /etc/xrdp/xrdp.ini

# Keep xorgxrdp logs out of the mounted user home.
if grep -Eq '^param=-logfile$' /etc/xrdp/sesman.ini; then
  sed -i '/^param=-logfile$/{n;s|^param=.*|param=/tmp/.xorgxrdp.%s.log|;}' /etc/xrdp/sesman.ini
fi

apply_container_firewall() {
  [ "$CONTAINER_FIREWALL" = 1 ] || return 0
  command -v nft >/dev/null 2>&1 || {
    echo "Error: CONTAINER_FIREWALL=1 but nft is not installed." >&2
    exit 1
  }

  cat > /tmp/container-filter.nft <<EOF
flush ruleset

table inet container_filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept
    ct state established,related accept
    ct state invalid drop

    tcp dport $ingress_port accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF

  nft -f /tmp/container-filter.nft
}

start_sshd() {
  [ "$RDP_ACCESS_MODE" = ssh-tunnel ] || return 0

  mkdir -p /run/sshd
  for host_key in \
    "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key" \
    "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" \
    "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key"
  do
    if [ ! -r "$host_key" ]; then
      echo "Error: missing persistent SSH host key: $host_key" >&2
      exit 1
    fi
  done

  cat > /etc/ssh/sshd_config <<EOF
Port $SSH_PORT
ListenAddress 0.0.0.0
HostKey $SSH_HOST_KEYS_DIR/ssh_host_ed25519_key
HostKey $SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key
HostKey $SSH_HOST_KEYS_DIR/ssh_host_rsa_key
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowTcpForwarding yes
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
PermitTTY no
AllowUsers $RDP_USER
EOF

  /usr/sbin/sshd
}

start_rdp_return_route_guard() {
  lan_dev="$(ip -4 route show default | awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  lan_gw="$(ip -4 route show default | awk 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "via") {print $(i + 1); exit}}')"

  [ -n "$lan_dev" ] || return 0

  (
    seen_clients=""
    while :; do
      rdp_clients="$(ss -tnH sport = ":$ingress_port" 2>/dev/null \
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
        echo "Pinned ingress return route for $rdp_client via ${lan_gw:-direct} dev $lan_dev"
      done
      sleep 2
    done
  ) &
}

apply_container_firewall
start_sshd
start_rdp_return_route_guard

/usr/sbin/xrdp-sesman --nodaemon &

exec /usr/sbin/xrdp --nodaemon
