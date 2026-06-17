#!/bin/sh
set -eu

script_path="/usr/local/bin/primary-clipboard_bridge.sh"
user_id="$(id -u)"
self_pid="$$"

# XRDP can leave old session helpers behind. More than one bridge fights over
# PRIMARY/CLIPBOARD ownership, so the newest session owns the bridge.
old_pids="$(ps -u "$user_id" -o pid= -o args= \
  | awk -v self_pid="$self_pid" -v script_path="$script_path" '
      $1 == self_pid {next}
      {
        pid = $1
        $1 = ""
        sub(/^[[:space:]]+/, "")
      }
      $0 == "/bin/sh " script_path || $0 == "sh " script_path || \
      $0 ~ "^/(usr/)?bin/(sh|dash|bash) " script_path "([[:space:]]|$)" {
        print pid
      }
    ')"
if [ -n "$old_pids" ]; then
  echo "Stopping older primary clipboard bridge process(es): $(echo "$old_pids" | xargs)"
  kill $old_pids 2>/dev/null || true
fi

echo "Starting primary clipboard bridge pid=$self_pid display=${DISPLAY:-unset}"

primary_last=""
clipboard_last=""

read_selection() {
  xclip -selection "$1" -o 2>/dev/null || true
}

write_selection() {
  selection="$1"
  text="$2"
  printf '%s' "$text" | xclip -selection "$selection" 2>/dev/null || true
}

while :; do
  primary_text="$(read_selection primary)"
  clipboard_text="$(read_selection clipboard)"

  if [ -n "$primary_text" ] && [ "$primary_text" != "$primary_last" ] && [ "$primary_text" != "$clipboard_text" ]; then
    write_selection clipboard "$primary_text"
    clipboard_text="$primary_text"
  elif [ -n "$clipboard_text" ] && [ "$clipboard_text" != "$clipboard_last" ] && [ "$clipboard_text" != "$primary_text" ]; then
    write_selection primary "$clipboard_text"
    primary_text="$clipboard_text"
  fi

  primary_last="$primary_text"
  clipboard_last="$clipboard_text"
  sleep 0.3
done
