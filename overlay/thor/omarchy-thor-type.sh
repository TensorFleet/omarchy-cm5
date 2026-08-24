#!/bin/bash
# D-pad letter picker used in place of `gum input` on the Thor.
# Navigation is arrows + Enter from omarchy-thor-kb.
set -euo pipefail

real=/usr/bin/gum
prompt="Input> "
password=0
placeholder=""

while (($#)); do
  case "$1" in
    --password) password=1; shift ;;
    --placeholder) placeholder=${2:-}; shift 2 ;;
    --prompt) prompt=${2:-$prompt}; shift 2 ;;
    --prompt.*) shift 2 ;;
    --header) shift 2 ;;
    input) shift ;;
    *) shift ;;
  esac
done

chars=(
  a b c d e f g h i j k l m n o p q r s t u v w x y z
  0 1 2 3 4 5 6 7 8 9
  . - _ @
  SPACE CAPS DEL DONE
)

value=""
caps=0

shown() {
  if ((password)); then
    local n=${#value} stars=""
    while ((n--)); do stars+='*'; done
    printf '%s' "$stars"
  else
    printf '%s' "$value"
  fi
}

while true; do
  clear
  printf '%s\n' "$prompt $(shown)"
  [[ -n $placeholder && -z $value ]] && printf '(%s)\n' "$placeholder"
  echo
  echo "D-pad move, A/B/Start = pick, Select/X = cancel, Y = delete"
  echo

  labels=()
  for ch in "${chars[@]}"; do
    case $ch in
      SPACE|CAPS|DEL|DONE) labels+=("$ch") ;;
      *)
        if ((caps)); then
          labels+=("${ch^^}")
        else
          labels+=("$ch")
        fi
        ;;
    esac
  done

  pick=$("$real" choose --height 12 "${labels[@]}") && st=0 || st=$?
  ((st == 0)) || exit "$st"
  case $pick in
    DONE) printf '%s\n' "$value"; exit 0 ;;
    DEL) value=${value%?} ;;
    SPACE) value+=' ' ;;
    CAPS) caps=$((1 - caps)) ;;
    *) value+="$pick" ;;
  esac
done
