# vpn-rdp-container

A lightweight Debian stable-slim desktop container for a VPN-confined RDP workflow.

```text
RDP client on host -> XRDP/JWM container -> OpenConnect VPN -> xfreerdp3
```

The current setup is intentionally **rootful Podman + macvlan DHCP only**. The container attaches directly to the LAN through the `PARENT_IFACE` configured in `run-rdp-container.env`, gets its own DHCP lease, and is reached directly by an RDP client on port `3389`.

The included VPN launcher uses OpenConnect. Set `VPN_PROTOCOL` in `user_home_volume/client.env` after first-run setup.

## Requirements

- Linux host with systemd
- rootful Podman with netavark DHCP support
- `iproute2` and `modprobe`
- a physical LAN interface that can be used as the macvlan parent
- an RDP client on the host or another LAN machine

Docker and rootless Podman are not supported by this setup.

## First run

Create/edit local credentials and network settings. `PARENT_IFACE` and `CONTAINER_MAC` are intentionally blank in the example; set them for your machine/LAN.

```bash
cp run-rdp-container.env.example run-rdp-container.env
ip -br link  # choose the physical LAN interface for PARENT_IFACE
$EDITOR run-rdp-container.env
```

Run rootful:

```bash
sudo ./run-rdp-container.sh
```

The script automatically:

- enables `netavark-dhcp-proxy.socket`
- syncs the shareable `user_home_template/` template into ignored `user_home_volume/` and fixes `user_home_volume` ownership to UID/GID `1000:1000`
- builds the image if needed
- creates a macvlan DHCP network on the configured `PARENT_IFACE`
- starts the container with the configured hostname, `/dev/net/tun`, `NET_ADMIN`, and a fixed MAC
- restarts an already-running container after syncing the home template, so session scripts pick up changes
- prints the MAC for router DHCP reservation and the DHCP address for your RDP client

Connect your RDP client to the printed target:

```text
<container-dhcp-ip>:3389
```

Login:

```text
user: configured by RDP_USER in run-rdp-container.env
pass: configured by RDP_PASSWORD in run-rdp-container.env
hostname: configured by CONTAINER_HOSTNAME in run-rdp-container.env
```

Inside the desktop:

```bash
cd ~
./vpn.sh
./rdp.sh
```


## Home template and runtime volume

`user_home_template/` is the small, shareable template committed to the repo. It intentionally contains only:

- `.jwmrc` for a minimal desktop/menu that launches a terminal, VPN, and inner RDP
- `vpn.sh`, `vpn.exp`, `rdp.sh`, and `geo_check.py`
- `client.env.example` with placeholder values only

`user_home_volume/` is ignored by git and is the directory actually mounted as `/home/${RDP_USER}`. `run-rdp-container.sh` creates it on first run. Each run refreshes template-managed files without deleting local runtime files such as `client.env`, logs, or app state.

Create container-side client credentials in the runtime volume. If you do this before the first run, create the directory first:

```bash
mkdir -p user_home_volume
cp user_home_template/client.env.example user_home_volume/client.env
$EDITOR user_home_volume/client.env
```

For the inner RDP target, set `WORKSPACE` as the primary address. Set `WORKSPACE_IP` only when you want to override it.

## Extra apt packages

Add optional Debian packages to `apt-packages.txt`, one package per line. Blank lines and `#` comments are ignored. These packages install in a separate Dockerfile layer, so changing extras reuses the cached base desktop/VPN layer.

Rebuild after changes:

```bash
sudo REBUILD=1 ./run-rdp-container.sh
```

## Useful overrides

```bash
# Rebuild image and recreate the container.
sudo REBUILD=1 ./run-rdp-container.sh

# Recreate container without rebuilding.
sudo RECREATE=1 ./run-rdp-container.sh

# Change PARENT_IFACE or CONTAINER_MAC in run-rdp-container.env, then recreate.
sudo RECREATE=1 ./run-rdp-container.sh

# Disable automatic chown of user_home_volume.
sudo FIX_HOME_OWNERSHIP=0 ./run-rdp-container.sh
```

## Notes

- The script prepares `/dev/net/tun` automatically when needed.
- `macvlan` does not use host port publishing; use the container DHCP IP directly.
- `CONTAINER_MAC` must be set in `run-rdp-container.env`; reserve that MAC on the router for a stable IP.
- The host should not join the VPN route. OpenConnect runs inside the container network namespace.


### XRDP login succeeds but X server could not be started

The image installs `xauth`, clears stale copied `.Xauthority`, and configures `/etc/X11/Xwrapper.config` for XRDP/Xorg container sessions. If this appears after an image change, rebuild and recreate:

```bash
sudo REBUILD=1 ./run-rdp-container.sh
```


### XRDP return route during VPN

The container entrypoint runs a small root route guard. It watches active XRDP clients on port `3389` and pins a `/32` return route through the original macvlan LAN path before the VPN can steal replies via `tun0`. Rebuild after entrypoint changes:

```bash
sudo REBUILD=1 ./run-rdp-container.sh
```


### Audio over XRDP

The image uses PipeWire for XRDP audio redirection and explicitly loads the XRDP PipeWire module from `startwm.sh` and installs `pipewire-module-xrdp`, `pipewire-pulse`, `wireplumber`, `pavucontrol`, `alsa-utils`, `pipewire-alsa`, `libasound2-plugins`, `xclip`, `xsel`, and `pulseaudio-utils`. The XRDP session starts PipeWire in `startwm.sh`.

After reconnecting KRDC, test inside the container desktop:

```bash
pactl info
pactl list short sinks
paplay /usr/share/sounds/alsa/Front_Center.wav
```

Your RDP client must have sound redirection enabled.


For audio diagnostics inside the desktop:

```bash
pactl info
pactl list short sinks
paplay /usr/share/sounds/alsa/Front_Center.wav
# or
speaker-test -D pipewire -t sine -f 440 -l 1
```



### Clipboard testing

XRDP clipboard syncs the X11 `CLIPBOARD` selection. To test manually inside the container desktop:

```bash
printf 'hello from container' | xclip -selection clipboard
xclip -selection clipboard -o
```

Test both directions:

1. Set `CLIPBOARD` with `xclip`, then paste on the host.
2. Copy text on the host, then read it with `xclip -selection clipboard -o` in the container.

For FreeRDP testing from the host, connect with clipboard enabled:

```bash
xfreerdp3 /v:<container-ip>:3389 /u:rdpuser /cert:ignore +clipboard /sound:sys:pulse
```


### Terminal selection clipboard bridge

The image autostarts `primary-clipboard_bridge.sh` in each XRDP session. It mirrors X11 `PRIMARY` and `CLIPBOARD` both ways, so terminal selection reaches the host clipboard and host-copied text is also available to terminal PRIMARY paste bindings such as `Ctrl+Ins`. Log output goes to `/tmp/primary-clipboard-bridge.log`.

## License

MIT. See [LICENSE](LICENSE).
