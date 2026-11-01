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

seed_steamcmd_bootstrap_packages() {
  local package_dir="$STEAMCMD_HOME/Steam/package"
  local manifest="$package_dir/steam_cmd_steamrt64"
  local name hash tmp parsed=0

  mkdir -p "$package_dir"
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
STEAMCMD_BOOTSTRAP_ID="${STEAMCMD_BUILD_ID:-unknown}-${STEAM_PLATFORM}-isolated-home-1"
if [[ -e "$UPDATE_BLOCKED" ]]; then
  BLOCKED_BUILD_ID="$(cat "$UPDATE_BLOCKED" 2>/dev/null || true)"
  if [[ "$BLOCKED_BUILD_ID" == "$STEAMCMD_BOOTSTRAP_ID" ]]; then
    echo "ERROR: La dernière mise à jour Steam a échoué sur cette image; nouvelle tentative bloquée pour éviter une boucle."
    echo "Après correction Steam, supprime $UPDATE_BLOCKED puis redémarre. Journal: $UPDATE_LOG"
    exit 0
  fi
  echo "Nouvelle image SteamCMD détectée; nouvel essai de mise à jour autorisé."
  rm -f "$UPDATE_BLOCKED"
fi
if [[ ! -x "$STEAMCMD_BIN" ]]; then
  echo "ERROR: SteamCMD absent de l'image ($STEAMCMD_BIN). Reconstruis l'image Docker locale."
  exit 2
fi
mkdir -p "$GAME_ROOT" "$ROOT/.home"
export HOME="${HOME:-$ROOT/.home}"
mkdir -p "$HOME"
export STEAMCMD_HOME="${STEAMCMD_HOME:-$ROOT/.steamcmd-home}"
mkdir -p "$STEAMCMD_HOME"

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
  echo "Aucun compte configuré; essai de connexion anonyme à Steam."
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
    fi
    continue
  fi
  break
done
if [[ $STEAMCMD_OK -ne 1 ]]; then
  printf '%s\n' "$STEAMCMD_BOOTSTRAP_ID" > "$UPDATE_BLOCKED"
  echo "ERROR: SteamCMD n'a pas confirmé la mise à jour. Le serveur ne démarre pas pour éviter une installation incomplète et les redémarrages en boucle."
  echo "Consulte $UPDATE_LOG; corrige l'accès Steam puis supprime $UPDATE_BLOCKED pour réessayer."
  exit 0
fi
rm -f "$UPDATE_BLOCKED"

for f in "$PULSAR_BIN" "$GAME2_DIR/SpaceEngineers2.exe" "$GAME2_DIR/SpaceEngineers2.dll" "$GAME2_DIR/VRage.Core.dll" "$CONFIG"; do
  if [[ ! -f "$f" ]]; then echo "ERROR: fichier requis absent: $f"; exit 2; fi
done
if [[ ! -x "$PULSAR_BIN" ]]; then echo "ERROR: Modern.bin n'est pas executable. Extrais Pulsar Linux et conserve son droit d'execution."; exit 2; fi
if [[ ! -f "$ROOT/Y51_SE2Online/Y51_SE2Online.xml" ]]; then echo "ERROR: descriptor Y51 local absent."; exit 2; fi

if ! command -v Xvfb >/dev/null 2>&1; then echo "ERROR: Xvfb manque dans l’image Linux."; exit 2; fi
Xvfb :99 -screen 0 1024x768x24 -nolisten tcp -ac >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null || true' EXIT
sleep 1
if ! kill -0 "$XVFB_PID" 2>/dev/null; then echo "ERROR: le serveur X virtuel Pulsar n’a pas démarré."; exit 2; fi
export DISPLAY=:99
export SDL_VIDEODRIVER=offscreen
export SE2_CPU_RENDERING=1
export DOTNET_ROOT="${DOTNET_ROOT:-$ROOT/dotnet}"
export DOTNET_ROOT_X64="$DOTNET_ROOT"
export DOTNET_MULTILEVEL_LOOKUP=0
mkdir -p "$HOME" "$PULSAR_DIR/Modern/Sources" "$PULSAR_DIR/Modern/Profiles"

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
