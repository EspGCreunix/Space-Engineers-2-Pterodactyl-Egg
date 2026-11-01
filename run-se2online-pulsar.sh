#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME2_DIR="${SE2_GAME2_DIR:-$ROOT/steamapps/common/SpaceEngineers2/Game2}"
GAME_ROOT="${SE2_GAME_DIR:-$(dirname "$GAME2_DIR")}"
PULSAR_DIR="${SE2_PULSAR_DIR:-$ROOT/pulsar}"
PULSAR_BIN="$PULSAR_DIR/Modern.bin"
CONFIG="${SE2_SERVER_CONFIG:-$ROOT/server.json}"
STEAMCMD_BIN="${STEAMCMD:-/opt/steamcmd/steamcmd.sh}"
# Steam's current bootstrap manifest targets SteamRT64. The bundled wrapper
# otherwise defaults to linux32 on x86_64 and can loop on an unapplied update.
export STEAM_PLATFORM="${STEAM_PLATFORM:-linux64}"

# A user may remove server.json while repairing a broken setup. Recreate a
# safe default atomically, then apply Pterodactyl's Startup variables below.
if [[ ! -f "$CONFIG" ]]; then
  CONFIG_DIR="$(dirname "$CONFIG")"
  mkdir -p "$CONFIG_DIR"
  CONFIG_TMP="$(mktemp "$CONFIG_DIR/.server.json.XXXXXX")"
  cat > "$CONFIG_TMP" <<'JSON'
{
  "SaveId": "",
  "StartContent": "",
  "StartWorkshop": "",
  "WorldName": "Classic Survival 1",
  "EnableAutosave": true,
  "SaveIntervalSeconds": 300,
  "SaveOnExit": true,
  "ShutdownCountdownSeconds": 60,
  "Network": {
    "SessionName": "SE2 Online Server",
    "Password": "",
    "Advertise": true,
    "FriendsOnly": false,
    "AllowDirectIp": true,
    "BindAddress": "0.0.0.0",
    "ListenPort": 27016
  }
}
JSON
  chmod 0644 "$CONFIG_TMP"
  mv -n -- "$CONFIG_TMP" "$CONFIG"
  if [[ -e "$CONFIG_TMP" ]]; then
    rm -f -- "$CONFIG_TMP"
    echo "server.json a été recréé entre-temps; le fichier existant est conservé."
  else
    echo "server.json absent; configuration par défaut recréée dans $CONFIG."
  fi
fi

seed_steamcmd_bootstrap_packages() {
  local package_dir="$STEAMCMD_HOME/Steam/package"
  local legacy_package_dir
  local manifest="$package_dir/steam_cmd_steamrt64"
  local name hash tmp cached parsed=0
  local -a cached_packages=()
  local -a legacy_package_dirs=("$ROOT/.steamcmd-home/Steam/package" "$HOME/Steam/package")

  mkdir -p "$package_dir"
  for legacy_package_dir in "${legacy_package_dirs[@]}"; do
    [[ "$legacy_package_dir" != "$package_dir" && -d "$legacy_package_dir" ]] || continue
    shopt -s nullglob
    cached_packages=("$legacy_package_dir"/*)
    shopt -u nullglob
    for cached in "${cached_packages[@]}"; do
      [[ -f "$cached" ]] && cp -n "$cached" "$package_dir/"
    done
  done
  if [[ ! -s "$manifest" ]] || ! grep -Fq '"steamrt64"' "$manifest"; then
    tmp="$manifest.download"
    echo "Récupération du manifeste SteamCMD depuis client-update.steamstatic.com."
    if ! curl -fsSL --retry 3 --connect-timeout 15 \
      https://client-update.steamstatic.com/steam_cmd_steamrt64 -o "$tmp"; then
      rm -f "$tmp"
      echo "ERROR: impossible de récupérer le manifeste SteamCMD."
      return 1
    fi
    mv -f "$tmp" "$manifest"
  fi

  while IFS=$'\t' read -r name hash; do
    [[ -n "$name" && -n "$hash" ]] || continue
    ((parsed += 1))
    tmp="$package_dir/$name.download"
    if [[ -f "$package_dir/$name" ]] && \
       printf '%s  %s\n' "$hash" "$package_dir/$name" | sha256sum -c --status; then
      continue
    fi

    echo "Récupération du paquet SteamCMD $name depuis media.steampowered.com."
    if ! curl -fL --retry 3 --connect-timeout 15 \
      "https://media.steampowered.com/client/$name" -o "$tmp"; then
      rm -f "$tmp"
      echo "ERROR: téléchargement impossible pour $name."
      return 1
    fi
    if ! printf '%s  %s\n' "$hash" "$tmp" | sha256sum -c --status; then
      rm -f "$tmp"
      echo "ERROR: empreinte invalide pour le paquet SteamCMD $name."
      return 1
    fi
    mv -f "$tmp" "$package_dir/$name"
  done < <(awk '
    /^[[:space:]]*"steamcmd_[^"]+"[[:space:]]*$/ {
      package = $1; gsub(/"/, "", package)
      full = ""; fullsha = ""; compressed = ""; compressedsha = ""
      inpkg = 0
      next
    }
    package != "" && /^[[:space:]]*\{[[:space:]]*$/ { inpkg = 1; next }
    inpkg && /^[[:space:]]*"file"[[:space:]]/ { full = $2; gsub(/"/, "", full) }
    inpkg && /^[[:space:]]*"sha2"[[:space:]]/ { fullsha = $2; gsub(/"/, "", fullsha) }
    inpkg && /^[[:space:]]*"zipvz"[[:space:]]/ { compressed = $2; gsub(/"/, "", compressed) }
    inpkg && /^[[:space:]]*"sha2vz"[[:space:]]/ { compressedsha = $2; gsub(/"/, "", compressedsha) }
    inpkg && /^[[:space:]]*}[[:space:]]*$/ {
      if (package ~ /^steamcmd_/) {
        if (compressed != "" && compressedsha != "") print compressed "\t" compressedsha
        else if (full != "" && fullsha != "") print full "\t" fullsha
      }
      package = ""; inpkg = 0
    }
  ' "$manifest")

  if [[ "$parsed" -eq 0 ]]; then
    echo "ERROR: aucun paquet SteamCMD exploitable dans le manifeste."
    return 1
  fi
  echo "Paquets bootstrap SteamCMD vérifiés : $parsed."
}

# SteamCMD writes into the existing game folder. Keep its app manifest and update
# metadata on the persistent Pterodactyl volume so later starts only fetch deltas.
UPDATE_BLOCKED="$ROOT/.steamcmd-update-blocked"
UPDATE_LOG="$ROOT/.steamcmd-update.log"
UPDATE_RETRY_COOLDOWN_SECONDS="${STEAMCMD_RETRY_COOLDOWN_SECONDS:-900}"
STEAM_ACCOUNT_ID="anonymous"
if [[ -n "${STEAM_USERNAME:-}" ]]; then
  STEAM_ACCOUNT_ID="$(printf '%s' "$STEAM_USERNAME" | sha256sum | cut -c1-16)"
fi
STEAMCMD_BOOTSTRAP_ID="${STEAMCMD_BUILD_ID:-unknown}-${STEAM_PLATFORM}-isolated-home-6-${STEAM_ACCOUNT_ID}"
if [[ -e "$UPDATE_BLOCKED" ]]; then
  BLOCKED_BUILD_ID="$(cat "$UPDATE_BLOCKED" 2>/dev/null || true)"
  if [[ "$BLOCKED_BUILD_ID" == "$STEAMCMD_BOOTSTRAP_ID" ]]; then
    BLOCKED_AT="$(sed -n '2p' "$UPDATE_BLOCKED" 2>/dev/null || true)"
    NOW="$(date +%s)"
    if [[ "$BLOCKED_AT" =~ ^[0-9]+$ ]] && (( NOW - BLOCKED_AT < UPDATE_RETRY_COOLDOWN_SECONDS )); then
      RETRY_IN=$((UPDATE_RETRY_COOLDOWN_SECONDS - (NOW - BLOCKED_AT)))
      echo "ERROR: tentative Steam précédente échouée; nouvelle tentative automatique dans environ $(( (RETRY_IN + 59) / 60 )) min."
      echo "Le changement de compte ou d'image autorise immédiatement une nouvelle tentative. Journal: $UPDATE_LOG"
      exit 0
    fi
    echo "Délai de sécurité écoulé; nouvelle tentative Steam automatique."
    rm -f "$UPDATE_BLOCKED"
  fi
  if [[ -e "$UPDATE_BLOCKED" ]]; then
    echo "Nouvelle image ou nouveau compte Steam détecté; nouvel essai de mise à jour autorisé."
    rm -f "$UPDATE_BLOCKED"
  fi
fi
if [[ ! -x "$STEAMCMD_BIN" ]]; then
  echo "ERROR: SteamCMD absent de l'image ($STEAMCMD_BIN). Reconstruis l'image Docker locale."
  exit 2
fi
# Pterodactyl runs this image with a read-only root filesystem. SteamCMD's
# self-updater must replace files beside its executable. Keep its writable copy
# on the persistent server volume (the container's /tmp can be very small).
STEAMCMD_IMAGE_BIN="$STEAMCMD_BIN"
STEAMCMD_RUNTIME_BIN="$ROOT/.steamcmd-runtime"
STEAMCMD_IMAGE_BUILD_ID="${STEAMCMD_BUILD_ID:-unknown}"
STEAMCMD_IMAGE_BUILD_MARKER="$STEAMCMD_RUNTIME_BIN/.image-build-id"
if [[ ! -x "$STEAMCMD_RUNTIME_BIN/steamcmd.sh" ]] || \
   [[ "$(cat "$STEAMCMD_IMAGE_BUILD_MARKER" 2>/dev/null || true)" != "$STEAMCMD_IMAGE_BUILD_ID" ]]; then
  echo "Initialisation de SteamCMD dans le volume persistant du serveur."
  mkdir -p "$STEAMCMD_RUNTIME_BIN"
  cp -R "$(dirname "$STEAMCMD_IMAGE_BIN")/." "$STEAMCMD_RUNTIME_BIN/"
  printf '%s\n' "$STEAMCMD_IMAGE_BUILD_ID" > "$STEAMCMD_IMAGE_BUILD_MARKER"
fi
STEAMCMD_BIN="$STEAMCMD_RUNTIME_BIN/steamcmd.sh"
mkdir -p "$GAME_ROOT" "$ROOT/.home"
export HOME="${HOME:-$ROOT/.home}"
mkdir -p "$HOME"

# SteamAPI looks in the user's sdk64 directory. The redistributable library is
# installed by SteamCMD in the image; seed it into the persistent container home.
STEAM_CLIENT_SOURCE="${STEAM_CLIENT_SOURCE:-/opt/steamcmd/linux64/steamclient.so}"
if [[ -f "$STEAM_CLIENT_SOURCE" && ! -f "$HOME/.steam/sdk64/steamclient.so" ]]; then
  mkdir -p "$HOME/.steam/sdk64"
  cp "$STEAM_CLIENT_SOURCE" "$HOME/.steam/sdk64/steamclient.so"
fi

# If the Windows Steam library manifest was copied to the existing server's
# steamapps root, seed SteamCMD's manifest in the selected install folder.
SOURCE_MANIFEST="$ROOT/steamapps/appmanifest_1133870.acf"
TARGET_MANIFEST="$GAME_ROOT/steamapps/appmanifest_1133870.acf"
if [[ -f "$SOURCE_MANIFEST" && ! -f "$TARGET_MANIFEST" ]]; then
  mkdir -p "$(dirname "$TARGET_MANIFEST")"
  cp "$SOURCE_MANIFEST" "$TARGET_MANIFEST"
fi

echo "Vérification Steam de SE2 (AppID 1133870) dans $GAME_ROOT; aucun dossier de jeu secondaire."
echo "SteamCMD platform: $STEAM_PLATFORM"
: > "$UPDATE_LOG"
STEAMCMD_OK=0
STEAM_LOGIN_ARGS=(+login anonymous)
STEAM_NO_PROMPT=1
if [[ -n "${STEAM_USERNAME:-}" ]]; then
  if [[ -z "${STEAM_PASSWORD:-}" ]]; then
    echo "ERROR: STEAM_USERNAME est renseigné mais STEAM_PASSWORD est vide."
    exit 2
  fi
  STEAM_LOGIN_ARGS=(+login "$STEAM_USERNAME" "$STEAM_PASSWORD")
  if [[ -z "${STEAMCMD_HOME:-}" ]]; then
    STEAM_ACCOUNT_HOME="$(printf '%s' "$STEAM_USERNAME" | sha256sum | cut -c1-16)"
    export STEAMCMD_HOME="$ROOT/.steamcmd-home/account-$STEAM_ACCOUNT_HOME"
  fi
  if [[ -n "${STEAM_GUARD_CODE:-}" ]]; then
    STEAM_LOGIN_ARGS+=("$STEAM_GUARD_CODE")
  else
    # Leave SteamCMD stdin interactive so its Steam Guard prompt can be answered
    # directly from the Pterodactyl console on first login.
    STEAM_NO_PROMPT=0
    echo "Steam Guard sera demandé dans la console Pterodactyl si nécessaire."
  fi
  echo "Connexion Steam avec le compte configuré dans les variables Pterodactyl."
elif [[ -n "${STEAM_PASSWORD:-}" || -n "${STEAM_GUARD_CODE:-}" ]]; then
  echo "ERROR: renseigne STEAM_USERNAME avec le mot de passe ou le code Steam Guard."
  exit 2
else
  if [[ -z "${STEAMCMD_HOME:-}" ]]; then
    export STEAMCMD_HOME="$ROOT/.steamcmd-home/anonymous"
  fi
  echo "Aucun compte configuré; essai de connexion anonyme à Steam."
fi
mkdir -p "$STEAMCMD_HOME"
# SteamCMD keeps bootstrap install state in HOME/Steam/package separately from
# its executable under /opt/steamcmd. Seed the verified build-time state into
# each isolated account home, preserving any account-local files already there.
STEAMCMD_IMAGE_PACKAGE="${STEAMCMD_IMAGE_HOME:-/opt/steamcmd-home}/Steam/package"
STEAMCMD_ACCOUNT_PACKAGE="$STEAMCMD_HOME/Steam/package"
if [[ -d "$STEAMCMD_IMAGE_PACKAGE" ]]; then
  mkdir -p "$STEAMCMD_ACCOUNT_PACKAGE"
  cp -an "$STEAMCMD_IMAGE_PACKAGE/." "$STEAMCMD_ACCOUNT_PACKAGE/"
fi

# SteamCMD's updater stalls when its HOME is used directly from the Pterodactyl
# bind mount. Run from a writable temporary copy, then persist account state on
# exit. The game install directory remains on the persistent server volume.
STEAMCMD_PERSISTENT_HOME="$STEAMCMD_HOME"
STEAMCMD_RUNTIME_HOME="$(mktemp -d /tmp/se2-steamcmd-home.XXXXXX)"
cp -R "$STEAMCMD_PERSISTENT_HOME/." "$STEAMCMD_RUNTIME_HOME/"
STEAMCMD_HOME="$STEAMCMD_RUNTIME_HOME"
steamcmd_persist_home() {
  if [[ -n "${STEAMCMD_RUNTIME_HOME:-}" && -d "$STEAMCMD_RUNTIME_HOME" ]]; then
    mkdir -p "$STEAMCMD_PERSISTENT_HOME"
    cp -R "$STEAMCMD_RUNTIME_HOME/." "$STEAMCMD_PERSISTENT_HOME/" || \
      echo "WARNING: impossible de recopier entièrement l'état SteamCMD dans $STEAMCMD_PERSISTENT_HOME" >&2
  fi
}
steamcmd_sync_home() {
  if [[ -n "${STEAMCMD_RUNTIME_HOME:-}" && -d "$STEAMCMD_RUNTIME_HOME" ]]; then
    steamcmd_persist_home
    rm -rf -- "$STEAMCMD_RUNTIME_HOME"
  fi
}
trap steamcmd_sync_home EXIT

STEAMCMD_BOOTSTRAP_LOG="$ROOT/.steamcmd-bootstrap.log"
STEAMCMD_WARMUP_MARKER="$STEAMCMD_PERSISTENT_HOME/.warmup-${STEAMCMD_IMAGE_BUILD_ID}-${STEAM_PLATFORM}"
steamcmd_warmup() {
  local warmup_attempt status attempt_log
  : > "$STEAMCMD_BOOTSTRAP_LOG"
  for warmup_attempt in 1 2; do
    attempt_log="$ROOT/.steamcmd-bootstrap-attempt.log"
    : > "$attempt_log"
    echo "Préparation de SteamCMD avant la mise à jour du jeu (étape $warmup_attempt/2)."
    set +e
    HOME="$STEAMCMD_HOME" "$STEAMCMD_BIN" +quit 2>&1 | tee -a "$STEAMCMD_BOOTSTRAP_LOG" "$attempt_log"
    status=${PIPESTATUS[0]}
    set -e
    steamcmd_persist_home
    if [[ $status -eq 0 ]] && grep -Fq "Steam Console Client" "$attempt_log"; then
      return 0
    fi
    if [[ $warmup_attempt -eq 1 ]]; then
      echo "SteamCMD n'a pas encore atteint sa console; vérification et récupération de ses paquets bootstrap."
      seed_steamcmd_bootstrap_packages || true
    fi
  done
  return 1
}

# SteamCMD's self-update is checked during app_update too. Warm it up only once
# per image/account/platform; on later starts this avoids an extra SteamCMD
# launch. The app_update retry path below still performs recovery if Valve has
# published a new SteamCMD bootstrap since the marker was written.
if [[ -f "$STEAMCMD_WARMUP_MARKER" ]]; then
  echo "Préparation SteamCMD déjà effectuée pour cette image et ce compte; contrôle des mises à jour du jeu."
else
  if ! steamcmd_warmup; then
    printf '%s\n%s\n' "$STEAMCMD_BOOTSTRAP_ID" "$(date +%s)" > "$UPDATE_BLOCKED"
    echo "ERROR: SteamCMD n'a pas terminé son démarrage autonome. Journal: $STEAMCMD_BOOTSTRAP_LOG"
    exit 0
  fi
  : > "$STEAMCMD_WARMUP_MARKER"
fi

for attempt in 1 2; do
  if [[ $attempt -eq 2 ]]; then
    echo "SteamCMD s’est fermé sans confirmer SE2; nouvel essai unique après son auto-mise à jour."
  fi
  set +e
  STEAMCMD_ARGS=(+@ShutdownOnFailedCommand 1)
  if [[ "$STEAM_NO_PROMPT" -eq 1 ]]; then
    STEAMCMD_ARGS+=(+@NoPromptForPassword 1)
  fi
  STEAMCMD_ARGS+=(+@sSteamCmdForcePlatformType windows +force_install_dir "$GAME_ROOT" \
    "${STEAM_LOGIN_ARGS[@]}" +app_update 1133870 +quit)
  HOME="$STEAMCMD_HOME" "$STEAMCMD_BIN" "${STEAMCMD_ARGS[@]}" 2>&1 | tee -a "$UPDATE_LOG"
  STEAMCMD_STATUS=${PIPESTATUS[0]}
  set -e
  steamcmd_persist_home
  if [[ $STEAMCMD_STATUS -eq 0 ]] && grep -Fq "Success! App '1133870'" "$UPDATE_LOG"; then
    STEAMCMD_OK=1
    break
  fi
  # SteamCMD may exit after its own first-run update or a transient download
  # failure without confirming app_update. Retry once in this same container.
  if [[ $attempt -eq 1 ]]; then
    # SteamCMD's bootstrap currently points at a broken Akamai DNS alias on
    # some networks. If it exited before opening its console, fetch its
    # signed-by-hash bootstrap packages from Steam's reachable media mirror.
    if ! grep -Fq "Steam Console Client" "$UPDATE_LOG"; then
      seed_steamcmd_bootstrap_packages || true
      if ! steamcmd_warmup; then
        printf '%s\n%s\n' "$STEAMCMD_BOOTSTRAP_ID" "$(date +%s)" > "$UPDATE_BLOCKED"
        echo "ERROR: SteamCMD n'a pas terminé sa mise à jour bootstrap après récupération des paquets. Journal: $STEAMCMD_BOOTSTRAP_LOG"
        exit 0
      fi
    fi
    continue
  fi
  break
done
if [[ $STEAMCMD_OK -ne 1 ]]; then
  printf '%s\n%s\n' "$STEAMCMD_BOOTSTRAP_ID" "$(date +%s)" > "$UPDATE_BLOCKED"
  echo "ERROR: SteamCMD n'a pas confirmé la mise à jour. Le serveur ne démarre pas pour éviter une installation incomplète et les redémarrages en boucle."
  echo "Consulte $UPDATE_LOG; nouvel essai automatique après 15 min, ou immédiatement après changement d'image ou de compte."
  exit 0
fi
rm -f "$UPDATE_BLOCKED"

for f in "$PULSAR_BIN" "$GAME2_DIR/SpaceEngineers2.exe" "$GAME2_DIR/SpaceEngineers2.dll" "$GAME2_DIR/VRage.Core.dll" "$CONFIG"; do
  if [[ ! -f "$f" ]]; then echo "ERROR: fichier requis absent: $f"; exit 2; fi
done
if [[ ! -x "$PULSAR_BIN" ]]; then echo "ERROR: Modern.bin n'est pas executable. Extrais Pulsar Linux et conserve son droit d'execution."; exit 2; fi
if [[ ! -f "$ROOT/Y51_SE2Online/Y51_SE2Online.xml" ]]; then echo "ERROR: descriptor Y51 local absent."; exit 2; fi

# Wings exposes the primary Pterodactyl allocation as SERVER_PORT. Keep the
# dedicated server's listen port in sync on every boot, including after a user
# changes the allocation in the panel.
if [[ -n "${SERVER_PORT:-}" ]]; then
  if [[ ! "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] || (( SERVER_PORT < 1 || SERVER_PORT > 65534 )); then
    echo "ERROR: SERVER_PORT doit être un port entre 1 et 65534 pour garder le port de requête suivant disponible. Valeur reçue: '$SERVER_PORT'."
    exit 2
  fi
  CONFIG_TMP="$(mktemp)"
  if ! awk -v port="$SERVER_PORT" '
    /^[[:space:]]*"Network"[[:space:]]*:[[:space:]]*\{/ { in_network=1 }
    in_network && /^[[:space:]]*"ListenPort"[[:space:]]*:/ {
      if (sub(/:[[:space:]]*[0-9]+/, ": " port) != 1) exit 42
      found++
    }
    in_network && /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/ { in_network=0 }
    { print }
    END { if (found != 1) exit 42 }
  ' "$CONFIG" > "$CONFIG_TMP"; then
    rm -f "$CONFIG_TMP"
    echo "ERROR: impossible de trouver exactement Network.ListenPort dans $CONFIG; configuration non modifiée."
    exit 2
  fi
  cat "$CONFIG_TMP" > "$CONFIG"
  rm -f "$CONFIG_TMP"
  echo "Network.ListenPort synchronisé avec l'allocation Pterodactyl : $SERVER_PORT (port de requête attendu : $((SERVER_PORT + 1)))."
fi

# Apply the Pterodactyl Startup choices to the dedicated config. Session mode
# is stored in the world's GameModeObjectBuilder; StartContent is only a seed
# for creating a new world and remains empty by default to preserve old saves.
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 manque dans l'image pour appliquer les variables de jeu."
  exit 2
fi
SE2_GAME_MODE="${SE2_GAME_MODE:-Survival}"
SE2_SERVER_NAME="${SE2_SERVER_NAME:-}"
# This is the game join password only. Never fall back to STEAM_PASSWORD:
# Steam credentials are used exclusively by SteamCMD above.
SE2_SERVER_PASSWORD="${SE2_SERVER_PASSWORD:-}"
SE2_ADMIN_STEAM_IDS="${SE2_ADMIN_STEAM_IDS:-}"
SE2_START_CONTENT="${SE2_START_CONTENT:-}"
SE2_VANILLA_RESPAWN_SHIPS="${SE2_VANILLA_RESPAWN_SHIPS:-0}"
SE2_BLOCK_PROGRESSION="${SE2_BLOCK_PROGRESSION:-0}"
SE2_WORKER_THREADS="${SE2_WORKER_THREADS:-0}"
SE2_CATCH_UP_MS="${SE2_CATCH_UP_MS:-1000}"
SE2_SERVER_PASSWORD="$SE2_SERVER_PASSWORD" python3 - "$CONFIG" "$SE2_GAME_MODE" "$SE2_SERVER_NAME" "$SE2_ADMIN_STEAM_IDS" "$SE2_START_CONTENT" "$SE2_VANILLA_RESPAWN_SHIPS" "$SE2_BLOCK_PROGRESSION" "$SE2_WORKER_THREADS" "$SE2_CATCH_UP_MS" <<'PY'
import json, os, re, sys, tempfile

path, mode, server_name, admin_ids_raw, start_content, vanilla_ships, block_progression, worker_threads_raw, catch_up_raw = sys.argv[1:]
server_password = os.environ.get("SE2_SERVER_PASSWORD", "")
if mode not in ("Survival", "Creative"):
    raise SystemExit("ERROR: SE2_GAME_MODE doit être Survival ou Creative.")
if len(server_name) > 100 or any(ord(ch) < 32 or ord(ch) == 127 for ch in server_name):
    raise SystemExit("ERROR: SE2_SERVER_NAME doit contenir au plus 100 caractères sans saut de ligne; vide pour garder Network.SessionName dans server.json.")
if len(server_password) > 64 or any(ord(ch) < 32 or ord(ch) == 127 for ch in server_password):
    raise SystemExit("ERROR: SE2_SERVER_PASSWORD doit contenir au plus 64 caractères sans caractère de contrôle.")
admin_ids = [item for item in re.split(r"[,;\s]+", admin_ids_raw.strip()) if item]
if any(not re.fullmatch(r"7656119\d{10}", item) for item in admin_ids):
    raise SystemExit("ERROR: SE2_ADMIN_STEAM_IDS doit contenir des SteamID64 de 17 chiffres commençant par 7656119, séparés par des virgules.")
admin_ids = list(dict.fromkeys(admin_ids))
if vanilla_ships.lower() not in ("0", "1", "false", "true", "off", "on"):
    raise SystemExit("ERROR: SE2_VANILLA_RESPAWN_SHIPS doit être 0/1 ou true/false.")
if block_progression.lower() not in ("0", "1", "false", "true", "off", "on"):
    raise SystemExit("ERROR: SE2_BLOCK_PROGRESSION doit être 0/1 ou true/false.")
try:
    worker_threads = int(worker_threads_raw)
    catch_up_ms = int(catch_up_raw)
except ValueError:
    raise SystemExit("ERROR: SE2_WORKER_THREADS et SE2_CATCH_UP_MS doivent être des nombres entiers.")
if not 0 <= worker_threads <= 256:
    raise SystemExit("ERROR: SE2_WORKER_THREADS doit être entre 0 (automatique) et 256.")
if not 0 <= catch_up_ms <= 10000:
    raise SystemExit("ERROR: SE2_CATCH_UP_MS doit être entre 0 et 10000; 0 désactive le rattrapage au-delà du seuil natif de Keen.")
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
if start_content and cfg.get("SaveId", "").strip():
    raise SystemExit("ERROR: SE2_START_CONTENT ne peut pas être utilisé avec SaveId; vide SaveId pour démarrer un scénario neuf.")
cfg["StartContent"] = start_content
# Admins belong in the permission system's Admin group, not in the stronger
# OwnerSteamIds bypass list. Keep that list empty when migrating old egg values.
cfg["OwnerSteamIds"] = []
cfg["WorkerThreads"] = worker_threads
cfg["CatchUpMs"] = catch_up_ms
cfg.setdefault("SessionSettings", {})
builder = cfg["SessionSettings"].setdefault(
    "Keen.Game2.Simulation.GameSystems.Player.GameModeObjectBuilder", {})
builder["CreativeGlobal"] = mode == "Creative"
network = cfg.setdefault("Network", {})
if server_name.strip():
    network["SessionName"] = server_name.strip()
else:
    network.setdefault("SessionName", "SE2 Online Server")
network["Password"] = server_password
network["VanillaRespawnShips"] = vanilla_ships.lower() in ("1", "true", "on")
network["Progression"] = block_progression.lower() in ("1", "true", "on")
directory = os.path.dirname(os.path.abspath(path))
fd, tmp = tempfile.mkstemp(prefix=".server.json.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
except BaseException:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise

# Populate the Admin group used by SE2 Online and mirror these IDs into
# access.json, as the plugin reconciles players.json against that list at load.
# Keep snapshots so changing the Pterodactyl variable can undo only our entries.
permissions_dir = os.path.join(directory, "Permissions")
players_path = os.path.join(permissions_dir, "players.json")
access_path = os.path.join(directory, "access.json")
managed_path = os.path.join(permissions_dir, ".pterodactyl-admin-steam-ids.json")
os.makedirs(permissions_dir, exist_ok=True)
try:
    with open(players_path, "r", encoding="utf-8") as f:
        player_file = json.load(f)
except FileNotFoundError:
    player_file = {"Version": 1, "Players": {}, "MirroredAdmins": []}
if not isinstance(player_file, dict):
    raise SystemExit("ERROR: Permissions/players.json doit contenir un objet JSON.")
player_file.setdefault("Version", 1)
player_file.setdefault("Players", {})
player_file.setdefault("MirroredAdmins", [])
if not isinstance(player_file["Players"], dict) or not isinstance(player_file["MirroredAdmins"], list):
    raise SystemExit("ERROR: Permissions/players.json doit contenir Players (objet) et MirroredAdmins (liste).")
try:
    with open(managed_path, "r", encoding="utf-8") as f:
        previous_managed = json.load(f)
except FileNotFoundError:
    previous_managed = {}
if not isinstance(previous_managed, dict):
    raise SystemExit("ERROR: le suivi des admins Pterodactyl est invalide; sauvegarde-le puis supprime Permissions/.pterodactyl-admin-steam-ids.json.")
managed_players = previous_managed.get("Players", {})
managed_access = previous_managed.get("AccessAdmins", {})
if not isinstance(managed_players, dict) or not isinstance(managed_access, dict):
    raise SystemExit("ERROR: le suivi des admins Pterodactyl est invalide; sauvegarde-le puis supprime Permissions/.pterodactyl-admin-steam-ids.json.")
current = set(admin_ids)
try:
    with open(access_path, "r", encoding="utf-8") as f:
        access_file = json.load(f)
except FileNotFoundError:
    access_file = {"Version": 1, "Admins": [], "Bans": [], "Whitelist": []}
if not isinstance(access_file, dict) or not isinstance(access_file.get("Admins", []), list):
    raise SystemExit("ERROR: access.json doit contenir Admins sous forme de liste.")
access_file.setdefault("Admins", [])
for steam_id, record in managed_players.items():
    if steam_id not in current:
        if player_file["Players"].get(steam_id) == record.get("managed"):
            previous = record.get("previous")
            if previous is None:
                player_file["Players"].pop(steam_id, None)
            else:
                player_file["Players"][steam_id] = previous
for steam_id, record in managed_access.items():
    if steam_id not in current:
        admins = access_file["Admins"]
        index = next((i for i, item in enumerate(admins) if isinstance(item, dict) and str(item.get("SteamId", "")) == steam_id), None)
        if index is not None:
            previous = record.get("previous")
            if previous is None:
                admins.pop(index)
            else:
                admins[index] = previous
next_managed_players = {}
next_managed_access = {}
for steam_id in admin_ids:
    previous_record = managed_players.get(steam_id)
    previous = previous_record.get("previous") if previous_record is not None else player_file["Players"].get(steam_id)
    existing = player_file["Players"].get(steam_id)
    if not isinstance(existing, dict):
        existing = {}
    assignment = dict(existing)
    assignment["Group"] = "Admin"
    assignment.setdefault("Name", "")
    player_file["Players"][steam_id] = assignment
    next_managed_players[steam_id] = {"previous": previous, "managed": assignment}
    admins = access_file["Admins"]
    access_index = next((i for i, item in enumerate(admins) if isinstance(item, dict) and str(item.get("SteamId", "")) == steam_id), None)
    previous_access_record = managed_access.get(steam_id)
    if previous_access_record is not None:
        # The game may fill in a real player name after first launch; keep managing
        # membership by SteamID while retaining the original entry for removal.
        if access_index is None:
            admins.append(previous_access_record["managed"])
        next_managed_access[steam_id] = previous_access_record
    elif access_index is None:
        access_entry = {"SteamId": int(steam_id), "Name": ""}
        admins.append(access_entry)
        next_managed_access[steam_id] = {"previous": None, "managed": access_entry}
def atomic_json(target, data):
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(target) + ".", dir=os.path.dirname(target), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, target)
    except BaseException:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
        raise
atomic_json(players_path, player_file)
atomic_json(access_path, access_file)
atomic_json(managed_path, {"Version": 1, "Players": next_managed_players, "AccessAdmins": next_managed_access})
print(f"Mode global SE2 : {mode}.")
print(f"Nom du serveur : {network['SessionName']} ({'variable Pterodactyl' if server_name.strip() else 'server.json'}).")
print(f"Mot de passe de connexion : {'configuré' if server_password else 'aucun'}.")
print(f"Admins configurés dans Permissions/players.json (groupe Admin) : {len(admin_ids)}.")
print(f"Threads de travail du jeu : {'automatique' if worker_threads == 0 else worker_threads}.")
print(f"Rattrapage des ticks : {catch_up_ms} ms.")
if start_content:
    print(f"Scénario de départ pour un nouveau monde : {start_content}.")
else:
    print("Aucun scénario forcé; reprise du monde défini par SaveId/WorldName s'il existe.")
print(f"Vaisseaux de respawn vanilla : {'activés' if network['VanillaRespawnShips'] else 'désactivés'}.")
print(f"Progression des blocs SE2 Online : {'activée (blocs à débloquer)' if network['Progression'] else 'désactivée (tous les blocs accessibles)'}.")
PY

if ! command -v Xvfb >/dev/null 2>&1; then echo "ERROR: Xvfb manque dans l’image Linux."; exit 2; fi
Xvfb :99 -screen 0 1024x768x24 -nolisten tcp -ac >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null || true; steamcmd_sync_home' EXIT
sleep 1
if ! kill -0 "$XVFB_PID" 2>/dev/null; then echo "ERROR: le serveur X virtuel Pulsar n’a pas démarré."; exit 2; fi
export DISPLAY=:99
export SDL_VIDEODRIVER=offscreen
export SE2_CPU_RENDERING=1
export DOTNET_ROOT="${DOTNET_ROOT:-$ROOT/dotnet}"
export DOTNET_ROOT_X64="$DOTNET_ROOT"
export DOTNET_MULTILEVEL_LOOKUP=0
mkdir -p "$HOME" "$PULSAR_DIR/Modern/Sources" "$PULSAR_DIR/Modern/Profiles"

# LinuxCompat is compiled from source during Pulsar startup. Five minutes
# avoids the default 30-second timeout on this large plugin without requiring
# a manual edit of Pulsar's per-server config.xml.
PULSAR_CONFIG_XML="$PULSAR_DIR/Modern/config.xml"
if [[ ! -f "$PULSAR_CONFIG_XML" ]]; then
  cat > "$PULSAR_CONFIG_XML" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<CoreConfig><CompilerTimeout>300000</CompilerTimeout></CoreConfig>
EOF
elif grep -Eq '<CompilerTimeout>[[:space:]]*[0-9]+[[:space:]]*</CompilerTimeout>' "$PULSAR_CONFIG_XML"; then
  sed -E -i 's#<CompilerTimeout>[[:space:]]*[0-9]+[[:space:]]*</CompilerTimeout>#<CompilerTimeout>300000</CompilerTimeout>#' "$PULSAR_CONFIG_XML"
elif grep -q '<CoreConfig[[:space:]>]' "$PULSAR_CONFIG_XML"; then
  sed -i '/<CoreConfig[[:space:]>]/a\  <CompilerTimeout>300000</CompilerTimeout>' "$PULSAR_CONFIG_XML"
else
  echo "ERROR: format inattendu dans $PULSAR_CONFIG_XML; CompilerTimeout non configuré."
  exit 2
fi
echo "Délai de compilation Pulsar/LinuxCompat configuré à 300000 ms (5 minutes)."

# Seed only missing config files. Use root-relative plugin folder so uploads can be relocated.
if [[ ! -f "$PULSAR_DIR/Modern/Sources/sources.xml" ]]; then
cat > "$PULSAR_DIR/Modern/Sources/sources.xml" <<EOF
<?xml version="1.0"?>
<SourcesConfig><ShowWarning>false</ShowWarning><MaxSourceAge>2</MaxSourceAge><LocalHubSources/><RemoteHubSources/><RemotePluginSources/><LocalPluginSources><LocalPlugin><Name>SE2 Online Linux headless</Name><Folder>$ROOT/Y51_SE2Online</Folder><File>Y51_SE2Online.xml</File><Enabled>true</Enabled></LocalPlugin></LocalPluginSources><ModSources/></SourcesConfig>
EOF
fi
if [[ ! -f "$PULSAR_DIR/Modern/Profiles/Current.xml" ]]; then
cat > "$PULSAR_DIR/Modern/Profiles/Current.xml" <<'EOF'
<?xml version="1.0"?>
<Profile><Name>Current</Name><GitHub/><DevFolder><LocalFolderConfig><Id>5EA5AFEC-6B23-44C1-91C4-A5FB5A68090B</Id><DebugBuild>false</DebugBuild></LocalFolderConfig></DevFolder><Local/><Mods/></Profile>
EOF
fi
cd "$PULSAR_DIR"
echo "Experimental SE2Online native Linux headless; config=$CONFIG"
exec 3<&0
"$PULSAR_BIN" -noUpdate -sources -noPrompt -noSplash -lazySteam -noDiscord -noStats -multiInstance -game2 "$GAME2_DIR" \
  -allowMultiple -localDedicatedServer -y51headless "-y51dedicated:$CONFIG" </dev/null 3<&- &
PULSAR_PID=$!

# Wings writes the egg stop command to stdin. Keep that input on the wrapper, not Pulsar,
# and translate it to Y51's command file so its final-save path runs before the process exits.
forward_panel_commands() {
  local command
  while IFS= read -r command; do
    case "${command,,}" in
      stop|"stop now")
        printf 'stop now\n' > "$ROOT/dedicated-command.txt"
        echo "Pterodactyl stop forwarded to Y51; waiting for the final world save."
        ;;
      *)
        echo "Console input ignored by the headless runner; use RCON for administration."
        ;;
    esac
  done
}
forward_panel_commands <&3 &
INPUT_PID=$!

set +e
wait "$PULSAR_PID"
EXIT_CODE=$?
kill "$INPUT_PID" 2>/dev/null || true
wait "$INPUT_PID" 2>/dev/null || true
exec 3<&-
exit "$EXIT_CODE"
