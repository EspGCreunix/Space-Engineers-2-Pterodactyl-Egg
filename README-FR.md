# Egg Pterodactyl — Space Engineers 2 / SE2 Online (Linux)

Paquet public expérimental pour créer un serveur Space Engineers 2 headless sous Linux avec Pulsar, LinuxCompat et le plugin SE2 Online adapté. Les fichiers du jeu ne sont jamais inclus dans l’image Docker ni dans le dépôt.

## Ce que fait l’egg

- À l’installation, récupère Pulsar Linux, le code SE2 Online et les composants LinuxCompat nécessaires, puis crée un `server.json` de départ.
- Au premier démarrage, SteamCMD tente de télécharger Space Engineers 2 (AppID `1133870`) en version Windows, utilisée par LinuxCompat.
- À chaque démarrage suivant, SteamCMD vérifie la version publiée et applique les mises à jour dans le même dossier persistant. Il n’utilise pas `validate`, qui recontrôlerait tous les fichiers.
- Si Steam refuse le téléchargement ou la mise à jour, le script bloque les tentatives suivantes pour éviter une boucle de crash. Après correction, il faut supprimer `.steamcmd-update-blocked` puis redémarrer.
- Le bouton Stop Pterodactyl envoie `stop now` à SE2 Online pour demander la sauvegarde finale.

## Publication de l’image

Le workflow GitHub Actions construit et publie `ghcr.io/espgcreunix/se2online-pulsar:latest` sur un push dans `main`.

Après le premier push :

1. Attendre la réussite de l’action **Publish Pterodactyl image**.
2. Dans GitHub, ouvrir le package `se2online-pulsar` et régler sa visibilité sur **Public**. Le dépôt public ne rend pas automatiquement le package GHCR public.
3. Importer `egg-se2online-pterodactyl.json` dans Pterodactyl.
4. Créer un serveur avec cet egg, choisir une allocation UDP (par défaut `27016`) et le démarrer. Le téléchargement initial du jeu peut être volumineux.

## Accès Steam

Chaque joueur doit posséder Space Engineers 2 sur Steam pour utiliser le jeu conformément à sa licence. L’egg essaie d’abord une connexion anonyme SteamCMD. Si Steam ne permet pas le téléchargement anonyme de l’AppID 1133870, l’installation automatique du jeu échouera : le journal `.steamcmd-update.log` affichera la réponse Steam et il faudra fournir les fichiers obtenus légalement par un compte possédant le jeu. Ne publie jamais un mot de passe Steam dans l’egg, `server.json` ou le dépôt.

La connexion à l’annuaire des serveurs, l’allocation des ports et la compatibilité LinuxCompat dépendent aussi de la version actuelle du jeu et de la configuration réseau du nœud. L’egg est donc expérimental et doit d’abord être validé sur un serveur de test.

## Versions et mises à jour

Le contenu du jeu est vérifié auprès de Steam à chaque lancement; SteamCMD conserve son manifeste dans le volume du serveur et ne télécharge normalement que les données modifiées. Pulsar est épinglé en v2.4.3 dans l’installation de l’egg. Pour changer de version Pulsar ou de code SE2 Online, publier une nouvelle version du dépôt puis réinstaller l’egg sur le serveur concerné (une réinstallation peut toucher aux fichiers du serveur : sauvegarder le monde avant).

## Licences

- SE2 Online : `Y51_SE2Online/LICENSE` — conserver l’avis de droit d’auteur et la restriction de distribution gratuite avec toute redistribution.
- Pulsar : `THIRD_PARTY_NOTICES/Pulsar-LICENSE`.
- LinuxCompat2 : `THIRD_PARTY_NOTICES/LinuxCompat-LICENSE`.
- Space Engineers 2 n’est pas redistribué par ce projet. Les utilisateurs doivent obtenir les fichiers via Steam et respecter la licence du jeu.

Ce paquet ne garantit pas qu’une future mise à jour de SE2 restera compatible avec le plugin headless. Garde une sauvegarde du monde avant une mise à jour majeure.
