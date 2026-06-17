#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

exec dbus-run-session -- sh -lc '
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"

  pipewire >/tmp/pipewire.log 2>&1 &
  pipewire-pulse >/tmp/pipewire-pulse.log 2>&1 &
  wireplumber >/tmp/wireplumber.log 2>&1 &

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pactl info >/dev/null 2>&1 && break
    sleep 0.5
  done

  xrdp_pw_loader="$(find /usr -path "*pipewire-module-xrdp*" -name load_pw_modules.sh -type f -executable 2>/dev/null | head -n 1)"
  if [ -n "$xrdp_pw_loader" ]; then
    "$xrdp_pw_loader" >/tmp/pipewire-xrdp.log 2>&1 || true
  else
    echo "pipewire-module-xrdp loader not found" >/tmp/pipewire-xrdp.log
  fi


  /usr/local/bin/primary-clipboard_bridge.sh >/tmp/primary-clipboard-bridge.log 2>&1 &

  [ -r "$HOME/.Xresources" ] && command -v xrdb >/dev/null 2>&1 && xrdb -merge "$HOME/.Xresources" || true
  exec jwm
'
