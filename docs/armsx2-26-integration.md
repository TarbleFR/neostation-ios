# ARMSX2 iOS 2.6 dans NeoStation

Cette intégration reste sur `armsx2-26`, indépendamment du chantier RPCS3 sur
`swap`. Elle ne fusionne rien dans `experimental` ou `main`.

## Référence inspectée

- Tag officiel : `iOSv2.6.0`.
- Sources : `9d989ca933a85bb2f1d111fd3b9e5742ac7d2fbe`.
- IPA fournie, version 2.6.0 / build 260 :
  SHA-256 `1c170296e5199a500d84c0e1fe9b633bd8445e49a83c7a07fb2d453f93a00281`.
- Les 28 fichiers de shaders de cette IPA correspondent octet pour octet aux
  sources du tag : 12 presets CRT, LCD, scanlines et mise à l’échelle, avec leurs
  stages et dépendances. Aucun téléchargement n’est nécessaire pour ces presets.

Le framework reconstruit contient le cœur PCSX2/ARMSX2 et librashader Metal, pas
l’exécutable ou les delegates de l’application ARMSX2. Le seul patch canonique a
été rebasé sur le tag 2.6. Les ressources conservent leurs chemins relatifs.
Le framework et Rust ciblent iOS 18, conformément au minimum de NeoStation.

## Menu et persistance

`Graphismes` contient désormais `Shaders` et `Overlays de performances`, à côté
de la résolution, du format d’écran et des hacks GS existants. Les traductions
couvrent les douze langues de NeoStation.

Les shaders intégrés se sélectionnent directement. Le bouton de téléchargement
utilise le même pack RetroArch que l’application ARMSX2 :
`https://buildbot.libretro.com/assets/frontend/shaders_slang.zip` (environ 54 Mo).
Le téléchargement écrit un fichier temporaire, puis l’extracteur natif ARMSX2
prépare un dossier provisoire. L’installation ne devient visible qu’après une
extraction réussie contenant des presets. Elle conserve stages, includes et
textures et ne remplace pas un pack déjà utilisé par le moteur.

L’ABI C passe à 6 : un ancien cœur est rejeté explicitement. Les nouveaux appels
exposent le catalogue, le choix du shader, les niveaux d’OSD et l’installation du
pack. Les écritures par jeu utilisent une transaction INI et un seul reload sur
le thread CPU possédé par ARMSX2. La compilation du shader appartient au thread
GS. Les erreurs du moteur sont lisibles en rouvrant le menu après reprise.

Les identifiants `bundle:<chemin relatif>` et `data:<chemin relatif>` persistent,
et les chemins absolus dérivés sont réparés avant le chargement des INI au
lancement suivant. Un preset absent est désactivé sans toucher aux autres
réglages. Les chemins sortant des racines ou passant par un lien symbolique
extérieur sont rejetés.

Les overlays demandés sont les performances natives, comme confirmé par le
mainteneur : désactivé, simple, détaillé ou complet, avec FPS, vitesse, CPU/GPU,
résolution et frametimes selon le niveau. Ils sont persistés par jeu. Cette
intégration n’ajoute pas de cadres décoratifs ou de skins de contrôles tactiles.

## Validation et limites

Le workflow `ARMSX2 native core` valide les sources, les paramètres BIOS et le
cycle de fermeture/relancement, les fichiers de presets et leurs identifiants,
la persistance par jeu et les échecs d’écriture, les traductions, le menu UIKit
réel et la compilation du plugin hôte contre Flutter. Le binaire est refusé si
le moteur Metal est absent ou si les presets ne sont pas empaquetés. Son
`identity.json` lie le SHA hôte, le SHA des sources et le hash du framework.
Le validateur de l’IPA vérifie aussi les presets après packaging.

Les vérifications locales Linux confirment les contrats de cycle de vie sur les
sources 2.6 et les douze traductions. Les tests Foundation/UIKit et la compilation
arm64 nécessitent les tâches macOS. Aucune session de jeu sur iPhone n’a encore
validé le rendu, les performances ou la stabilité de cette intégration.

Avant fusion, tester un jeu PS2 connu : shaders désactivés, preset intégré, pack
téléchargé, réouverture du menu pour les erreurs, changement des quatre niveaux
d’overlay, fermeture et relancement, conservation du réglage par jeu, absence
d’effet sur un autre jeu. Comparer FPS/frametime et stutters avec et sans shader.
