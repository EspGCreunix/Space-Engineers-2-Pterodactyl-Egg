#!/usr/bin/env bash
set -Eeuo pipefail

# Install the upstream LinuxCompat Pulsar development source into one server
# volume. Usage: sudo bash install-linux-compat.sh /path/to/server-volume
ROOT="${1:-/home/container}"
CONTAINER_ROOT="${CONTAINER_ROOT:-/home/container}"
PULSAR="$ROOT/pulsar"
SOURCES="$PULSAR/Modern/Sources/sources.xml"
PROFILE="$PULSAR/Modern/Profiles/Current.xml"
PLUGIN="$ROOT/CometWorks/linux-compat2"
PLUGIN_CONTAINER_PATH="$CONTAINER_ROOT/CometWorks/linux-compat2"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "ERREUR: $*" >&2; exit 1; }
[[ -f "$PULSAR/Modern.bin" ]] || fail "Pulsar introuvable: $PULSAR/Modern.bin"
[[ -f "$SOURCES" ]] || fail "sources.xml absent: $SOURCES"
[[ -f "$PROFILE" ]] || fail "Current.xml absent: $PROFILE"
[[ -f "$ROOT/server.json" ]] || fail "server.json absent à la racine du serveur"
command -v curl >/dev/null || fail "curl est requis"
command -v tar >/dev/null || fail "tar est requis"
command -v sed >/dev/null || fail "sed est requis"

mkdir -p "$ROOT/CometWorks" "$ROOT/linux-dependencies/dist" "$ROOT/linux-native-wrappers/dist"

# Preserve existing files; never replace an existing plugin checkout silently.
if [[ ! -f "$PLUGIN/ClientPlugin/ClientPlugin.xml" ]]; then
  [[ ! -e "$PLUGIN" ]] || fail "$PLUGIN existe déjà mais ne contient pas ClientPlugin/ClientPlugin.xml; inspecte-le avant de continuer"
  curl -fL --retry 3 https://codeload.github.com/CometWorks/linux-compat2/tar.gz/refs/heads/main -o "$TMP/linux-compat2.tar.gz"
  tar -xzf "$TMP/linux-compat2.tar.gz" -C "$TMP"
  SRC_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'linux-compat2-*' -print -quit)"
  [[ -n "$SRC_DIR" && -f "$SRC_DIR/ClientPlugin/ClientPlugin.xml" ]] || fail "archive LinuxCompat invalide"
  mv "$SRC_DIR" "$PLUGIN"
fi

curl -fL --retry 3 https://github.com/CometWorks/linux-dependencies/releases/latest/download/se2-dependencies.tar.gz -o "$TMP/se2-dependencies.tar.gz"
curl -fL --retry 3 https://github.com/CometWorks/linux-native-wrappers/releases/latest/download/se2-native-wrappers.tar.gz -o "$TMP/se2-native-wrappers.tar.gz"
tar -tzf "$TMP/se2-dependencies.tar.gz" >/dev/null || fail "archive se2-dependencies invalide"
tar -tzf "$TMP/se2-native-wrappers.tar.gz" >/dev/null || fail "archive se2-native-wrappers invalide"
install -m 0644 "$TMP/se2-dependencies.tar.gz" "$ROOT/linux-dependencies/dist/se2-dependencies.tar.gz"
install -m 0644 "$TMP/se2-native-wrappers.tar.gz" "$ROOT/linux-native-wrappers/dist/se2-native-wrappers.tar.gz"

if ! grep -q '<Name>linux-compat</Name>' "$SOURCES"; then
  grep -q '</LocalPluginSources>' "$SOURCES" || fail "format sources.xml inattendu; aucun changement XML effectué"
  cp -a "$SOURCES" "$SOURCES.bak.$STAMP"
  sed -i "s#</LocalPluginSources>#<LocalPlugin><Name>linux-compat</Name><Folder>$PLUGIN_CONTAINER_PATH</Folder><File>ClientPlugin/ClientPlugin.xml</File><Enabled>true</Enabled></LocalPlugin></LocalPluginSources>#" "$SOURCES"
fi

if ! grep -q '<Id>linux-compat</Id>' "$PROFILE"; then
  grep -q '</DevFolder>' "$PROFILE" || fail "format Current.xml inattendu; aucun changement à ce fichier"
  cp -a "$PROFILE" "$PROFILE.bak.$STAMP"
  sed -i 's#</DevFolder>#<LocalFolderConfig><Id>linux-compat</Id><DebugBuild>true</DebugBuild></LocalFolderConfig></DevFolder>#' "$PROFILE"
fi

grep -q '<Name>linux-compat</Name>' "$SOURCES" || fail "plugin non enregistré dans sources.xml"
grep -q '<Id>linux-compat</Id>' "$PROFILE" || fail "plugin non activé dans Current.xml"
echo "LinuxCompat installé et activé. Sauvegardes XML: *.bak.$STAMP (si elles existaient)."
echo "Plugin: $PLUGIN"
echo "Redémarre le serveur une fois dans Pterodactyl pour le prochain test."
