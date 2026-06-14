FROM debian:stable-slim

ARG RDP_USER

ENV DEBIAN_FRONTEND=noninteractive
ENV RDP_USER=${RDP_USER}

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    xrdp \
    xorgxrdp \
    xserver-xorg-legacy \
    jwm \
    xterm \
    xauth \
    menu \
    x11-apps \
    x11-xserver-utils \
    bash \
    dbus-daemon \
    dbus-user-session \
    freerdp3-x11 \
    openconnect \
    openssh-server \
    nftables \
    sudo \
    iproute2 \
    iputils-ping \
    bind9-dnsutils \
    curl \
    python3 \
    expect \
    pipewire \
    pipewire-audio \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    pipewire-module-xrdp \
    pulseaudio-utils \
    pavucontrol \
    alsa-utils \
    libasound2-plugins \
    xclip \
    xsel \
    ca-certificates \
    procps \
    passwd \
    && rm -rf /var/lib/apt/lists/*

COPY apt-packages.txt /tmp/apt-packages.txt

RUN apt-get update \
    && sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' /tmp/apt-packages.txt \
      | xargs -r apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt

RUN groupadd -g 1000 "$RDP_USER" \
    && useradd -m -u 1000 -g 1000 -s /bin/bash "$RDP_USER" \
    && usermod -aG sudo "$RDP_USER" \
    && printf '%s ALL=(ALL) NOPASSWD: /usr/sbin/openconnect, /usr/sbin/ip, /usr/bin/ping\n' "$RDP_USER" > "/etc/sudoers.d/${RDP_USER}-vpn" \
    && chmod 0440 "/etc/sudoers.d/${RDP_USER}-vpn" \
    && (adduser xrdp ssl-cert || true)

COPY startwm.sh /etc/xrdp/startwm.sh
COPY entrypoint.sh /entrypoint.sh
COPY primary-clipboard_bridge.sh /usr/local/bin/primary-clipboard_bridge.sh

RUN chmod +x /etc/xrdp/startwm.sh /entrypoint.sh \
    && chmod +x /usr/local/bin/primary-clipboard_bridge.sh \
    && printf '%s\n' 'allowed_users=anybody' 'needs_root_rights=no' > /etc/X11/Xwrapper.config

EXPOSE 3389 2022

CMD ["/entrypoint.sh"]
