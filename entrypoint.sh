#!/bin/bash
set -e
cd /home/container

export TZ="${TZ:-UTC}"
INTERNAL_IP="$(ip route get 1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
export INTERNAL_IP

PARSED="$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g' | eval echo "$(cat -)")"
printf '\033[1m\033[33mcontainer@pterodactyl~ \033[0m%s\n' "$PARSED"
exec bash -c "$PARSED"
