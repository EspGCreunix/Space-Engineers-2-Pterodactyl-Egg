#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${SERVER_DIR:-/mnt/server}"
REPO_URL="https://github.com/EspGCreunix/se2online-pterodactyl/archive/refs/heads/main.tar.gz"
PULSAR_URL="https://github.com/SpaceGT/Pulsar/releases/download/v2.4.3/pulsar-v2.4.3-linux-x64.tar.gz"
PULSAR_SHA256="83c703d606f381a28fe6d740088ad3e368cff438db8d7e48d56142fcd02c61cf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for bin in curl tar sha256sum find; do
    command -v "$bin" >/dev/null || { echo "Missing installer tool: $bin"; exit 1; }
done

mkdir -p "$ROOT"
echo "Downloading the public SE2 Online Pterodactyl package..."
curl -fL --retry 3 "$REPO_URL" -o "$TMP/project.tar.gz"
tar -xzf "$TMP/project.tar.gz" -C "$TMP"
PROJECT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'se2online-pterodactyl-*' -print -quit)"
[[ -n "$PROJECT" ]] || { echo "Could not unpack project sources"; exit 1; }

if [[ ! -e "$ROOT/Y51_SE2Online" ]]; then
    cp -a "$PROJECT/Y51_SE2Online" "$ROOT/Y51_SE2Online"
fi
if [[ ! -e "$ROOT/run-se2online-pulsar.sh" ]]; then
    install -m 0755 "$PROJECT/run-se2online-pulsar.sh" "$ROOT/run-se2online-pulsar.sh"
fi
if [[ ! -e "$ROOT/install-linux-compat.sh" ]]; then
    install -m 0755 "$PROJECT/install-linux-compat.sh" "$ROOT/install-linux-compat.sh"
fi

mkdir -p "$TMP/pulsar" "$ROOT/pulsar"
echo "Downloading verified Pulsar Linux v2.4.3..."
curl -fL --retry 3 "$PULSAR_URL" -o "$TMP/pulsar.tar.gz"
echo "$PULSAR_SHA256  $TMP/pulsar.tar.gz" | sha256sum -c -
tar -xzf "$TMP/pulsar.tar.gz" -C "$TMP/pulsar"
PULSAR_BIN="$(find "$TMP/pulsar" -type f -name Modern.bin -print -quit)"
[[ -n "$PULSAR_BIN" ]] || { echo "Pulsar archive does not contain Modern.bin"; exit 1; }
if [[ ! -e "$ROOT/pulsar/Modern.bin" ]]; then
    cp -a "$(dirname "$PULSAR_BIN")/." "$ROOT/pulsar/"
fi
chmod +x "$ROOT/pulsar/Modern.bin"

mkdir -p "$ROOT/pulsar/Modern/Sources" "$ROOT/pulsar/Modern/Profiles"
if [[ ! -f "$ROOT/pulsar/Modern/Sources/sources.xml" ]]; then
    cat > "$ROOT/pulsar/Modern/Sources/sources.xml" <<'XML'
<?xml version="1.0"?>
<SourcesConfig><ShowWarning>false</ShowWarning><MaxSourceAge>2</MaxSourceAge><LocalHubSources/><RemoteHubSources/><RemotePluginSources/><LocalPluginSources><LocalPlugin><Name>SE2 Online Linux headless</Name><Folder>/home/container/Y51_SE2Online</Folder><File>Y51_SE2Online.xml</File><Enabled>true</Enabled></LocalPlugin></LocalPluginSources><ModSources/></SourcesConfig>
XML
fi
if [[ ! -f "$ROOT/pulsar/Modern/Profiles/Current.xml" ]]; then
    cat > "$ROOT/pulsar/Modern/Profiles/Current.xml" <<'XML'
<?xml version="1.0"?>
<Profile><Name>Current</Name><GitHub/><DevFolder><LocalFolderConfig><Id>5EA5AFEC-6B23-44C1-91C4-A5FB5A68090B</Id><DebugBuild>false</DebugBuild></LocalFolderConfig></DevFolder><Local/><Mods/></Profile>
XML
fi

if [[ ! -f "$ROOT/server.json" ]]; then
    cp "$PROJECT/server.example.json" "$ROOT/server.json"
fi

echo "Preparing LinuxCompat and its native dependency archives..."
CONTAINER_ROOT=/home/container bash "$ROOT/install-linux-compat.sh" "$ROOT"
echo "Installation complete. Start the server; SteamCMD will attempt the initial SE2 download."
