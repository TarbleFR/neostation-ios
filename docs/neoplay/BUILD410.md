# NeoPlay — Build 410

Candidat privé. Aucune validation sur iPhone, Windows physique, Chromecast ou Apple TV n'est revendiquée par cette build ; les preuves sont celles de la CI (harnais natif sur Simulateur iOS 18, récepteur Node et Edge sur Windows).

## Son sans grésillement (protocole « frames » v2 activé de bout en bout)

Défauts établis dans les sources de la Build 409 :

- l'audio ReplayKit partageait la file série de capture avec le rendu CoreImage 60 fps ; au-delà de seize tampons en attente, chaque tampon audio était rejeté sans trace (`NPCapture`), et le muxeur v1 rejetait aussi tout tampon arrivé pendant que l'entrée AAC de l'`AVAssetWriter` n'était pas prête (`NPMuxer`) : trous dans la piste AAC, clics ;
- le récepteur Windows lisait la piste fMP4 via MediaSource avec 0,3 s de tampon : sauts de `currentTime`, lecture à 1,03× et suppressions pendant la lecture, chacun audible ;
- le protocole v2 (une image par paquet, PCM brut) existait côté iPhone mais aucun récepteur ne l'annonçait ; son mot `configuration` était écrit par VideoToolbox et lu par la capture sans synchronisation.

Correction :

- émetteur : file audio dédiée (`neoplay.audio`), jamais derrière une image ; soixante-quatre tampons de marge comptés, jamais rejetés en silence ; mots partagés de l'encodeur sous verrou ; horodatage PCM par compteur de trames 48 kHz ; le transport délaisse d'abord les images (et demande une image clé) et ne délaisse le son que s'il remplit seul la file ;
- muxeur v1 (Chromecast, anciens récepteurs) : tampons différés au lieu d'être rejetés, silence inséré à la longueur exacte des trous de plus de 80 ms (formats entrelacés), compteurs ;
- récepteur : WebCodecs pour les images, AudioWorklet avec anneau PCM à l'échantillon près (`audio-ring.mjs`) : les trous sont comblés par du silence de la longueur exacte, les chevauchements rognés, la dérive corrigée par un rééchantillonnage de ±1,5 %, jamais par un saut ; les images sont présentées sur l'horloge audio (ou à leur rythme si le jeu est muet) ; le chemin MediaSource reste le repli.

## Image : capture native, 60 images/s, affichage 4K

ReplayKit capture l'écran de l'iPhone (2868 × 1320 sur un 16 Pro Max) : c'est la borne physique. Un récepteur « frames » annonce désormais un plafond de décodage de 7680 × 4320 et reçoit la capture native (45 Mbit/s à 12 bit/px/s, plafond 60 Mbit/s) ; il la met à l'échelle sans perte sur son écran, 4K compris. Les tampons natifs droits vont directement à l'encodeur, sans passe CoreImage. Trois paliers (natif, 1080p, 720p) pilotés par les paquets délaissés sur le lien (trois en deux secondes : palier inférieur ; vingt secondes calmes : palier supérieur). Les récepteurs MediaSource gardent le plafond 1080p validé.

## Bouton AirPlay

Cellule de la barre du menu principal, entre Recherche et Trophées, même taille que ses voisines (`MainMenuTabStrip`), jamais une superposition.

## Récepteur Windows

Mettre à jour `tools/neoplay-receiver` (`npm ci --ignore-scripts && npm start`) et ouvrir la page dans Edge ou Chrome : la page annonce `frames` dès que WebCodecs et AudioWorklet sont disponibles. L'état « Receiving · frames · … » confirme le protocole v2 ; « segments » indique le repli MediaSource.

## Vérifications CI

`neoplay-check` : tests Node du récepteur (protocole v2, anneau audio, relais), harnais natif (encodeur concurrent, politique de paliers, adaptateur de lien), lecture Edge des fixtures `windows.json` (v1) et `frames.json` (v2) produites par l'encodeur iOS, gate d'intégration NeoPlay (empreintes Build 410 du bridge), douze langues.
