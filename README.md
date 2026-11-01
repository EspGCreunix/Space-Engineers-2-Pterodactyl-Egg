# SE2 Online — egg Pterodactyl Linux

Egg and runtime image for an experimental headless SE2 Online server on Linux. See [README-FR.md](README-FR.md) for setup, Steam access, updates, ports, and limitations.

The game itself is not included. SteamCMD checks/updates AppID 1133870 in the persistent Pterodactyl volume before every launch. The initial download requires network access and may require a Steam entitlement; the project's public image contains only runtime dependencies and SteamCMD. The launcher uses SteamCMD's 64-bit client in a dedicated persistent home and can recover its bootstrap packages from Steam's media mirror if the bootstrap CDN is unavailable; downloaded packages are checked against the hashes in Steam's manifest.

SteamCMD tries anonymous access by default. If Steam requires ownership of Space Engineers 2, enter a dedicated Steam account's username and password in that server's Pterodactyl Startup variables. On first login, SteamCMD can prompt for a Steam Guard code in the Pterodactyl console, or the temporary code can be entered in its Startup variable. Pterodactyl variables are not a secure secret vault: use a dedicated account and never commit credentials to the egg or repository.

At each launch, the wrapper synchronizes `Network.ListenPort` with Pterodactyl's primary allocation (`SERVER_PORT`). Allocate the following UDP port as well for the game's query port. It also sets Pulsar's plugin compilation timeout to five minutes so LinuxCompat can compile on first start.

The Pterodactyl **Startup** tab lets you select the global `Survival` or `Creative` mode. `Starting Scenario` accepts vanilla content IDs such as `ClassicSurvival`, `Survival`, `SurvivalNOFTUE`, `CRF`, or `EmptyWorld`; it is blank by default to resume the current save. Selecting a scenario starts a new world, while preserving the old save in the volume. Set it back to blank to use the configured `SaveId`/`WorldName` world. SE2 Online opens a first-spawn/respawn menu with a space ship, planetary lander, and accessible medbays; `Offer Vanilla Respawn Ships` adds vanilla ships. Planetary choices require a world that contains a planet.

The optional **Server Name** Startup variable overrides `Network.SessionName`. Leave it blank to manage the name directly in `server.json`.

`Server Password` sets the join password; leave it blank for an open server. `Admin Steam IDs` accepts comma-separated SteamID64 values and assigns those players to the SE2 Online `Admin` group in `Permissions/players.json`, mirrored to `access.json`. Docker CPU pinning cannot be removed from inside the image: if the container has `Cpuset=0`, clear the host's CPU pinning in Pterodactyl/Wings. A .NET processor-count override cannot bypass that container restriction.

`Game Worker Threads` defaults to `0`, which lets the game choose its worker count. `Tick Catch-up (ms)` defaults to `1000`; setting it to `0` disables large catch-up bursts after a stall, but does not add CPU and can make simulation fall behind under load. Avoid setting every performance value to zero without checking what it controls.

If `server.json` is missing, the launcher recreates a default Survival configuration, then applies the Pterodactyl Startup variables and allocated server port.

## First start and world creation

The first startup can take a long time: SteamCMD downloads the game, and Pulsar compiles the server plugins for Linux. Later starts are normally faster; SteamCMD checks for game updates and downloads changed files when needed. When a new world is created for the first time, this setup may restart the server once while the world is initialized. Let that restart finish; it should then start normally with the new world.

## What updates automatically

- **Space Engineers 2 game files:** SteamCMD checks AppID 1133870 on each server start and updates the persistent installation when Steam has a newer build. A game update does not require reinstalling the egg.
- **Launcher script:** the container fetches the current `run-se2online-pulsar.sh` from this repository's `main` branch at startup. If GitHub cannot be reached, it uses the copy already in the server volume.
- **Runtime Docker image:** Pterodactyl pulls the configured image when starting the server. This project publishes a new `latest` image when changes to the Dockerfile or container entrypoint are pushed to `main`. This updates the container runtime, not the host's Pterodactyl/Wings installation.
- **SE2 Online plugin and LinuxCompat files:** these live in the persistent server volume. The startup launcher does not replace them automatically. Updating their source requires a project/egg update or reinstall; back up the world and server files first.
- **Pulsar:** the installer uses the verified Pulsar v2.4.3 release and preserves an existing installation. Pulsar is not self-updated at every startup; a newer version must be deliberately adopted by this project and installed for existing servers.

This is a custom Pterodactyl egg, Docker image, and startup integration. It combines existing projects rather than reusing one complete server-management system: SE2 Online by [Yellow51](https://se2-online.yellow51.dev/), [Pulsar](https://github.com/SpaceGT/Pulsar), and [LinuxCompat](https://github.com/CometWorks/linux-compat2), plus SteamCMD and Pterodactyl. See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for included notices.

Import `egg-se2online-pterodactyl.json`. GitHub Actions publishes `ghcr.io/espgcreunix/se2online-pulsar:latest` after the first push to `main`; make that GHCR package public so Pterodactyl can pull it.

The image refreshes the server-side launcher from the repository's `main` branch at startup, falling back to the installed copy if GitHub is unavailable. Reimport the egg JSON in Pterodactyl to expose new Startup variables on existing servers.
