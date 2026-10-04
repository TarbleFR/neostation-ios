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
La cible embarquée lie directement la dépendance Zstandard et reçoit ses
en-têtes depuis la cible CMake, même lorsque les sources du fournisseur changent
de dossier. Seul `ARMSX2Bridge.mm` est compilé en ARC, conformément au tag 2.6.
Le test de construction génère les véritables arguments du compilateur pour
contrôler cette propagation et préserver le mode mémoire des autres fichiers.
Les remplacements de chemins Rust/C/C++ sont capturés à la configuration CMake
et transmis explicitement à Cargo. Le test exécute la commande de production
après suppression des variables du shell : il refuse la commande amont et
valide la version adaptée. Le contrôle du binaire conserve un diagnostic détaillé
si un chemin de machine de build subsiste.
Les objets précompilés de la bibliothèque standard Rust ont aussi des entrées
de débogage `N_OSO` créées au lien. La cible applique `-oso_prefix` au dossier du
dépôt pour rendre ces origines relatives. Un test macOS construit une archive
minimale, reproduit le chemin absolu et vérifie sa suppression avec l'option
exacte générée par la cible Core ; les fonctions exportées restent vérifiées.
Le pont des sauvegardes rapides utilise les nouvelles signatures 2.6 à deux
arguments de retour. Les slots du menu gardent leur comportement existant, sans
création d'une sauvegarde d'annulation supplémentaire lors d'un chargement.

## Menu et persistance

`Graphismes` contient désormais `Shaders` et `Overlays de performances`, à côté
de la résolution, du format d’écran et des hacks GS existants. Les traductions
couvrent les douze langues de NeoStation.

Les shaders intégrés se sélectionnent directement. Une recherche filtre les noms
et chemins des presets sans modifier leur identifiant persistant. Le bouton de téléchargement
utilise le même pack RetroArch que l’application ARMSX2 :
`https://buildbot.libretro.com/assets/frontend/shaders_slang.zip` (environ 54 Mo).
Le pack actuellement vérifié contient 2 658 presets et 5 208 fichiers (54 274 055
octets compressés, 71 394 473 octets extraits). Il respecte les limites de
l’extracteur natif : 32 768 entrées, 8 Mio par fichier, 512 Mio au total.
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
le moteur Metal est absent ou si les 28 fichiers de shaders ne correspondent
pas octet pour octet aux sources épinglées. Son
`identity.json` lie le SHA hôte, le SHA des sources et le hash du framework.
Les workflows de packaging retirent le bootstrap ARMSX2 de l'ancienne IPA et
chargent l'artefact du run natif exact. Ils vérifient son SHA hôte, ses sources,
l'ABI 6, son hash, les shaders/overlays et le hash de chacun des 28 fichiers de
shaders après téléchargement de l'archive. L'upload conserve toutes ces ressources.
Le manifeste final enregistre cette nouvelle identité, plutôt que celle du donneur.
Le validateur de l’IPA vérifie aussi les presets après packaging. La notice GPL
ARMSX2 suit le tag 2.6, et les crédits incluent le runtime librashader épinglé ainsi
que l’attribution des presets intégrés.

Le run [37164423042](https://github.com/TarbleFR/neostation-ios/actions/runs/37164423042)
a réussi ses deux tâches le 4 octobre 2026 : framework iOS arm64, moteur Metal,
ABI/export/signature, ressources, tests Foundation, 4 tests UIKit et 29 tests Dart.
Les 100 cycles de lancement/arrêt sont des tests de contrat dans une fixture,
pas des démarrages de jeux sur iPhone.

- Producteur Core : `f4bdeb5e25f7622118a5c8ba23d8fc538e07ba07`.
- SHA-256 du binaire : `aca6afe92068a1803208675c84d2a13bb57f72bec6e383f93236929205c2588c`.
- SHA-256 de l'archive téléchargée :
  `61b3fed041b7d76065a895d6e3c29d52716ec356f330e09655c94c99987a3567`.
- 12 presets et 28 ressources iOS vérifiés à nouveau après téléchargement,
  octet pour octet contre le tag officiel.

`test/armsx2_packaging_test.py --archive <archive Core>` exécute les véritables
gardes Python des deux workflows sur cette archive. Les cas négatifs couvrent
ABI 5, mauvais SHA hôte, mauvais hash binaire et ressource manquante. Le test
vérifie aussi le remplacement du registre du donneur et la conservation des
identités RPCS3/Dolphin. Ces contrôles ont réussi sur l'archive ci-dessus.
Le commit de packaging peut être plus récent que le producteur : ses sources
Core/ABI/patch doivent rester identiques, ce que les workflows imposent.

Les vérifications locales Linux confirment les contrats de cycle de vie sur les
sources 2.6 et les douze traductions. Les tests Foundation/UIKit et la compilation
arm64 nécessitent les tâches macOS. Aucune session de jeu sur iPhone n’a encore
validé le rendu, les performances ou la stabilité de cette intégration.

Avant fusion, tester un jeu PS2 connu : shaders désactivés, preset intégré, pack
téléchargé, réouverture du menu pour les erreurs, changement des quatre niveaux
d’overlay, fermeture et relancement, conservation du réglage par jeu, absence
d’effet sur un autre jeu. Comparer FPS/frametime et stutters avec et sans shader.
