# SE2 Online — egg Pterodactyl Linux

Egg and runtime image for an experimental headless SE2 Online server on Linux. See [README-FR.md](README-FR.md) for setup, Steam access, updates, ports, and limitations.

The game itself is not included. SteamCMD checks/updates AppID 1133870 in the persistent Pterodactyl volume before every launch. The initial download requires network access and may require a Steam entitlement; the project's public image contains only runtime dependencies and SteamCMD.

SteamCMD tries anonymous access by default. If Steam requires ownership of Space Engineers 2, enter a dedicated Steam account's username and password in that server's Pterodactyl Startup variables. On first login, SteamCMD can prompt for a Steam Guard code in the Pterodactyl console, or the temporary code can be entered in its Startup variable. Pterodactyl variables are not a secure secret vault: use a dedicated account and never commit credentials to the egg or repository.

Import `egg-se2online-pterodactyl.json`. GitHub Actions publishes `ghcr.io/espgcreunix/se2online-pulsar:latest` after the first push to `main`; make that GHCR package public so Pterodactyl can pull it.
