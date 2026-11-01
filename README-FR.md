# Egg Pterodactyl — Space Engineers 2 / SE2 Online (Linux)

Paquet public expérimental pour créer un serveur Space Engineers 2 headless sous Linux avec Pulsar, LinuxCompat et le plugin SE2 Online adapté. Les fichiers du jeu ne sont jamais inclus dans l’image Docker ni dans le dépôt.

## Ce que fait l’egg

- À l’installation, récupère Pulsar Linux, le code SE2 Online et les composants LinuxCompat nécessaires, puis crée un `server.json` de départ.
- Au premier démarrage, SteamCMD tente de télécharger Space Engineers 2 (AppID `1133870`) en version Windows, utilisée par LinuxCompat.
- Le lanceur choisit SteamCMD 64 bits pour appliquer son manifeste SteamRT64. Si le CDN de démarrage Steam est indisponible, il récupère les paquets depuis le miroir officiel `media.steampowered.com` et vérifie leurs empreintes avant de relancer SteamCMD.
- L’état de SteamCMD est conservé dans `.steamcmd-home`, séparé de l’ancien cache Steam du serveur pour éviter qu’il perturbe son initialisation.
- À chaque démarrage suivant, SteamCMD vérifie la version publiée et applique les mises à jour dans le même dossier persistant. Il n’utilise pas `validate`, qui recontrôlerait tous les fichiers.
- Au démarrage, l’image récupère le lanceur actuel depuis la branche `main` de GitHub. Si GitHub est inaccessible, elle garde le lanceur déjà installé.
- À chaque démarrage, le lanceur règle `Network.ListenPort` sur le port principal attribué par Pterodactyl. Le port de requête attendu est le port suivant (`SERVER_PORT + 1`) : attribue aussi ce port au serveur dans **Network**.
- L’onglet **Startup** permet de choisir le mode global `Survival` ou `Creative`. Le choix est appliqué au chargement du monde.
- **Server Name** est une surcharge facultative de `Network.SessionName`. Laisse la variable vide pour régler le nom directement dans `server.json`.
- **Server Password** définit le mot de passe demandé aux joueurs à la connexion; vide, le serveur reste ouvert.
- **Admin Steam IDs** accepte une liste d’identifiants SteamID64 séparés par des virgules. Le lanceur inscrit ces comptes dans le groupe `Admin` de `Permissions/players.json` et les reflète dans `access.json`; ils ne sont pas ajoutés aux Owner Steam IDs.
- L’egg ne peut pas retirer l’affinité CPU imposée par Docker/Wings. Si `docker inspect` montre `Cpuset=0`, le conteneur est épinglé au processeur logique 0; retire le CPU pinning dans la configuration de l’hôte. Ajouter des threads ou modifier .NET dans l’image ne contourne pas cette restriction.
- Les variables `Game Worker Threads` (`0` = choix automatique, recommandé) et `Tick Catch-up (ms)` règlent les options du serveur dédié. Mettre `Tick Catch-up (ms)` à `0` évite les grosses rafales de rattrapage après un blocage, mais ne donne pas plus de CPU et peut ralentir la simulation quand le serveur est chargé. Ne mets pas toutes les valeurs à `0` au hasard.
- Si `server.json` est absent, le lanceur le recrée automatiquement avec une configuration Survival par défaut, puis applique les variables de démarrage Pterodactyl et le port alloué.
- `Starting Scenario` accepte les identifiants vanilla `ClassicSurvival`, `Survival`, `SurvivalNOFTUE`, `CRF` ou `EmptyWorld`. Il est vide par défaut pour reprendre la sauvegarde actuelle. Choisir un scénario démarre un nouveau monde; l’ancienne sauvegarde reste dans le volume. Pour revenir au monde géré par `SaveId`/`WorldName`, remets le champ à vide.
- SE2 Online affiche un menu de premier spawn et de respawn : vaisseau en espace, lander sur planète, ainsi que les médibays accessibles. La variable `Offer Vanilla Respawn Ships` ajoute les vaisseaux vanilla du jeu. Un choix sur planète n’est possible que si le scénario/sauvegarde contient une planète.
- Le délai de compilation des plugins Pulsar/LinuxCompat est réglé automatiquement à cinq minutes pour laisser compiler ce grand plugin au premier démarrage.
- Le premier démarrage peut être long : SteamCMD télécharge le jeu et Pulsar compile les plugins pour Linux. Les démarrages suivants sont normalement plus rapides. Lors de la toute première création d’un monde, le serveur peut redémarrer une fois pendant son initialisation; laisse ce redémarrage se terminer.
- Si Steam refuse le téléchargement ou la mise à jour, le script bloque les tentatives suivantes pour éviter une boucle de crash. Après correction, il faut supprimer `.steamcmd-update-blocked` puis redémarrer.
- Le bouton Stop Pterodactyl envoie `stop now` à SE2 Online pour demander la sauvegarde finale.

## Publication de l’image

Le workflow GitHub Actions construit et publie `ghcr.io/espgcreunix/se2online-pulsar:latest` sur un push dans `main`.

Après le premier push :

1. Attendre la réussite de l’action **Publish Pterodactyl image**.
2. Dans GitHub, ouvrir le package `se2online-pulsar` et régler sa visibilité sur **Public**. Le dépôt public ne rend pas automatiquement le package GHCR public.
3. Importer `egg-se2online-pterodactyl.json` dans Pterodactyl.
4. Créer un serveur avec cet egg, attribuer une allocation UDP principale et aussi le port UDP suivant pour les requêtes. Le lanceur synchronise automatiquement `Network.ListenPort` avec le port principal Pterodactyl. Le téléchargement initial du jeu peut être volumineux.

Après une mise à jour de l’egg, réimporte le JSON dans Pterodactyl pour faire apparaître ses nouveaux champs Startup sur les serveurs existants; le lanceur et l’image se mettent ensuite à jour au prochain démarrage.

## Accès Steam

Par défaut, SteamCMD tente un téléchargement anonyme. Si Steam exige une licence pour l’AppID 1133870, renseigne `Steam Username` et `Steam Password` dans l’onglet **Startup** du serveur Pterodactyl avec un compte qui possède Space Engineers 2. Lors d'une première connexion, SteamCMD peut demander un code Steam Guard dans la console Pterodactyl. Tu peux aussi le saisir temporairement dans le champ `Steam Guard Code`. Si le compte ou le code est refusé, le démarrage s'arrête et le journal `.steamcmd-update.log` indique l'erreur.

**Sécurité :** les variables d’egg sont transmises au conteneur et ne constituent pas un coffre-fort. Le panneau et le processus du serveur peuvent accéder aux valeurs; le mot de passe est également transmis à SteamCMD pendant la connexion. Utilise un compte Steam dédié qui ne contient aucun autre jeu ou moyen de paiement, et ne mets jamais d’identifiants réels dans l’egg, `server.json`, le dépôt GitHub ou les journaux. Chaque administrateur doit saisir ses propres valeurs dans son serveur Pterodactyl.

La connexion à l’annuaire des serveurs, l’allocation des ports et la compatibilité LinuxCompat dépendent aussi de la version actuelle du jeu et de la configuration réseau du nœud. L’egg est donc expérimental et doit d’abord être validé sur un serveur de test.

## Versions et mises à jour

Les composants n’ont pas tous le même mécanisme de mise à jour :

- **Fichiers de Space Engineers 2 :** SteamCMD vérifie l’AppID `1133870` à chaque démarrage et met à jour l’installation persistante si Steam propose une nouvelle version. Une mise à jour du jeu ne nécessite pas de réinstaller l’egg.
- **Lanceur :** au démarrage, le conteneur récupère `run-se2online-pulsar.sh` depuis la branche `main` de GitHub. Si GitHub est inaccessible, il utilise la copie déjà présente dans le volume.
- **Image Docker :** Pterodactyl récupère l’image configurée au démarrage. Ce dépôt publie `latest` lorsqu’une modification du Dockerfile ou de l’entrypoint est poussée sur `main`. Cela met à jour l’environnement du conteneur, pas l’installation Pterodactyl/Wings de l’hôte.
- **Plugin SE2 Online et fichiers LinuxCompat :** ils sont conservés dans le volume du serveur et ne sont pas remplacés automatiquement par le lanceur. Leur mise à jour doit être intégrée au projet puis appliquée volontairement au serveur. Sauvegarde le monde et les fichiers avant toute réinstallation ou remplacement.
- **Pulsar :** l’installation utilise la version vérifiée v2.4.3 et conserve une version déjà installée. Pulsar ne s’auto-met pas à jour à chaque démarrage; une nouvelle version doit être adoptée par le projet puis installée sur les serveurs concernés.
- **Pterodactyl/Wings et le système de l’hôte :** leur mise à jour est gérée par l’administrateur du nœud, en dehors de cet egg.

Ce projet fournit un egg Pterodactyl, une image Docker et un lanceur personnalisés. Il assemble plusieurs projets existants plutôt que de reprendre un système complet de gestion de serveur : SE2 Online de [Yellow51](https://se2-online.yellow51.dev/), [Pulsar](https://github.com/SpaceGT/Pulsar), [LinuxCompat](https://github.com/CometWorks/linux-compat2), SteamCMD et Pterodactyl. Voir [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) pour les avis de licence.

## Licences

- SE2 Online : `Y51_SE2Online/LICENSE` — conserver l’avis de droit d’auteur et la restriction de distribution gratuite avec toute redistribution.
- Pulsar : `THIRD_PARTY_NOTICES/Pulsar-LICENSE`.
- LinuxCompat2 : `THIRD_PARTY_NOTICES/LinuxCompat-LICENSE`.
- Space Engineers 2 n’est pas redistribué par ce projet. Les utilisateurs doivent obtenir les fichiers via Steam et respecter la licence du jeu.

Ce paquet ne garantit pas qu’une future mise à jour de SE2 restera compatible avec le plugin headless. Garde une sauvegarde du monde avant une mise à jour majeure.
