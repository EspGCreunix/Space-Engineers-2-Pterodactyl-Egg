#!/bin/bash
set -e
cd /home/container

export TZ="${TZ:-UTC}"
RUNNER_PATH=/home/container/run-se2online-pulsar.sh
RUNNER_TMP="$(mktemp /home/container/.run-se2online-pulsar.XXXXXX)"
if curl -fsSL --connect-timeout 5 --max-time 20 \
    https://raw.githubusercontent.com/EspGCreunix/se2online-pterodactyl/main/run-se2online-pulsar.sh \
    -o "$RUNNER_TMP"; then
  if [[ ! -f "$RUNNER_PATH" ]] || ! cmp -s "$RUNNER_TMP" "$RUNNER_PATH"; then
    chmod 0755 "$RUNNER_TMP"
    mv -f -- "$RUNNER_TMP" "$RUNNER_PATH"
    echo "Lanceur SE2 Online actualisé depuis GitHub."
  else
    rm -f -- "$RUNNER_TMP"
  fi
else
  rm -f -- "$RUNNER_TMP"
  echo "WARNING: GitHub est inaccessible; utilisation du lanceur SE2 Online déjà installé."
fi
if [[ -r /sys/fs/cgroup/cpuset.cpus.effective ]]; then
  EFFECTIVE_CPUSET="$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || true)"
  if [[ "$EFFECTIVE_CPUSET" == "0" ]]; then
    echo "WARNING: Docker pins this server to logical CPU 0 (cpuset.cpus.effective=0); the egg cannot remove a host CPU pinning restriction."
  fi
fi
INTERNAL_IP="$(ip route get 1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
export INTERNAL_IP

PARSED="$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g' | eval echo "$(cat -)")"
printf '\033[1m\033[33mcontainer@pterodactyl~ \033[0m%s\n' "$PARSED"
exec bash -c "$PARSED"
