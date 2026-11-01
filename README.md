# SE2 Online — egg Pterodactyl Linux

Egg and runtime image for an experimental headless SE2 Online server on Linux. See [README-FR.md](README-FR.md) for setup, Steam access, updates, ports, and limitations.

The game itself is not included. SteamCMD checks/updates AppID 1133870 in the persistent Pterodactyl volume before every launch. The initial download requires network access and may require a Steam entitlement; the project's public image contains only runtime dependencies and SteamCMD. The launcher uses SteamCMD's 64-bit client in a dedicated persistent home and can recover its bootstrap packages from Steam's media mirror if the bootstrap CDN is unavailable; downloaded packages are checked against the hashes in Steam's manifest.

SteamCMD tries anonymous access by default. If Steam requires ownership of Space Engineers 2, enter a dedicated Steam account's username and password in that server's Pterodactyl Startup variables. On first login, SteamCMD can prompt for a Steam Guard code in the Pterodactyl console, or the temporary code can be entered in its Startup variable. Pterodactyl variables are not a secure secret vault: use a dedicated account and never commit credentials to the egg or repository.

At each launch, the wrapper synchronizes `Network.ListenPort` with Pterodactyl's primary allocation (`SERVER_PORT`). Allocate the following UDP port as well for the game's query port. It also sets Pulsar's plugin compilation timeout to five minutes so LinuxCompat can compile on first start.

The Pterodactyl **Startup** tab lets you select the global `Survival` or `Creative` mode. `Starting Scenario` accepts vanilla content IDs such as `ClassicSurvival`, `Survival`, `SurvivalNOFTUE`, `CRF`, or `EmptyWorld`; it is blank by default to resume the current save. Selecting a scenario starts a new world, while preserving the old save in the volume. Set it back to blank to use the configured `SaveId`/`WorldName` world. SE2 Online opens a first-spawn/respawn menu with a space ship, planetary lander, and accessible medbays; `Offer Vanilla Respawn Ships` adds vanilla ships. Planetary choices require a world that contains a planet.

The **Server Name** Startup variable sets the name shown in the Space Engineers 2 server browser.

If `server.json` is missing, the launcher recreates a default Survival configuration, then applies the Pterodactyl Startup variables and allocated server port.

Import `egg-se2online-pterodactyl.json`. GitHub Actions publishes `ghcr.io/espgcreunix/se2online-pulsar:latest` after the first push to `main`; make that GHCR package public so Pterodactyl can pull it.
