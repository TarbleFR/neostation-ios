# NeoPlay Windows 0.7.0

NeoPlay installe une application Windows qui contient son récepteur, son lecteur Chromium et ses dépendances. Le logo fourni de NeoStation iOS apparaît dans la fenêtre, l’exécutable, l’installateur et les raccourcis. Interface et installateur : douze langues.

La qualité conserve les pixels de la capture lorsque le lien local le permet. Un retard persistant du réseau ou du décodeur déclenche le contrôle de congestion existant de NeoStation (demandes d’image clé, paliers native/1080p/720p, reprise après 20 secondes sans congestion). Les pics isolés, les pauses du jeu et une fenêtre masquée ne demandent pas une baisse de qualité.

Une vraie capture 3840 × 2160 à 60 fps peut être reçue et décodée avec le GPU. Les captures iPhone de résolution inférieure conservent leurs pixels natifs ; la mise à l’échelle vers un écran 4K est distincte de la résolution source. La fenêtre affiche la résolution reçue, celle du rendu et la cadence mesurée. Les réglages Original, Améliorée et Renforcée restent disponibles ; le rendu revient au Canvas 2D si WebGL échoue.

## Vérifications exécutées sur Windows

- 51 tests automatiques réussis : audio, protocole, association, reconnexion, adaptation, dimensions, visibilité et traductions.
- Lecture dans l’application réellement empaquetée d’un flux synthétique H.264 3840 × 2160, 60 fps, stéréo PCM 48 kHz : Original 238/240 images ; Améliorée 237/240 ; Renforcée 237/240.
- Aucun échec de décodage, aucune demande de baisse sur le lien de test, un seul chemin audio ; absence de trou ou de saut de l’horloge audio.
- Plein écran pendant le flux, arrêt et nouvelle association dans chaque mode.
- Instance unique, fermeture qui libère le port, relancement et conservation des préférences.
- Le lecteur n’expose pas Node.js ; isolation et sandbox du moteur intégré activées.

Ces essais utilisent un flux synthétique sur le PC. Ils ne constituent pas une nouvelle validation physique de ReplayKit, du Wi-Fi de l’iPhone ou du retour du volume local. Le code iOS, les émulateurs, NeoSwap et les règles audio de NeoStation n’ont pas été modifiés.

## Compilation reproductible

Dans tools/neoplay-receiver, sous Windows :

    npm ci --ignore-scripts
    npm test
    node node_modules/electron/install.js
    npm run build:windows
    npm run build:installer

Sorties : dist/win-unpacked/NeoPlay.exe et dist/NeoPlay-Setup-0.7.0.exe. Les fichiers build.json et installer.json associent les artefacts à la révision source et à leurs SHA-256. Le compilateur NSIS est téléchargé depuis sa distribution officielle pour Electron et vérifié par un SHA-256 fixé dans le script.
