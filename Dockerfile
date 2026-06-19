FROM debian:stable-slim

ARG RDP_USER
ARG CONTAINER_USER_UID=1000
ARG CONTAINER_USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_CTYPE=C.UTF-8
ENV RDP_USER=${RDP_USER}
ENV CONTAINER_USER_UID=${CONTAINER_USER_UID}
ENV CONTAINER_USER_GID=${CONTAINER_USER_GID}

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
    libcap2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && setcap cap_net_raw+ep /usr/bin/ping

# Keep SSH, xrdp, and login shells on Debian's built-in UTF-8 locale.
RUN printf '%s\n' 'LANG=C.UTF-8' 'LC_CTYPE=C.UTF-8' > /etc/default/locale

COPY apt-packages.txt /tmp/apt-packages.txt

RUN apt-get update \
    && sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' /tmp/apt-packages.txt \
      | xargs -r apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt

RUN groupadd -g "$CONTAINER_USER_GID" "$RDP_USER" \
    && useradd -m -u "$CONTAINER_USER_UID" -g "$CONTAINER_USER_GID" -s /bin/bash "$RDP_USER" \
    && usermod -aG sudo "$RDP_USER" \
    && printf '%s ALL=(ALL) NOPASSWD: /usr/sbin/openconnect, /usr/sbin/ip, /usr/bin/ping\n' "$RDP_USER" > "/etc/sudoers.d/${RDP_USER}-vpn" \
    && chmod 0440 "/etc/sudoers.d/${RDP_USER}-vpn" \
    && (adduser xrdp ssl-cert || true)

COPY guest/scripts/startwm.sh /etc/xrdp/startwm.sh
COPY guest/scripts/entrypoint.sh /entrypoint.sh
COPY guest/scripts/primary-clipboard_bridge.sh /usr/local/bin/primary-clipboard_bridge.sh

RUN chmod +x /etc/xrdp/startwm.sh /entrypoint.sh \
    && chmod +x /usr/local/bin/primary-clipboard_bridge.sh \
    && printf '%s\n' 'allowed_users=anybody' 'needs_root_rights=no' > /etc/X11/Xwrapper.config

EXPOSE 3389 2022

CMD ["/entrypoint.sh"]
