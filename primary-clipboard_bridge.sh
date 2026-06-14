#!/bin/sh
set -eu

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
