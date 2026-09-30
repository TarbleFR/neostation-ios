# Mises à jour natives du 30 septembre 2026

Périmètre demandé : Dusklight 2.0.3, Mario Kart Pad 0.7.2 et investigation
de l'import des cheats signalé pour Enter the Matrix. L'ajout de commandes
de menu à la manette a été annulé par le mainteneur.

## Dusklight 2.0.3

La référence amont est `40457c6adb381928e4b5fef6ed459ed291edd5e2`, avec
Aurora `3227d76c60e1e782ca576610bce61c9e7744d8be` et
Borealis `4ac5e7052a8c49a122f8d57f626b5c75c5ca6968`.
SDL reste à la référence 3.4.10 déjà intégrée.

Les vingt commits supplémentaires comprennent notamment la correction du
faux état de carte mémoire corrompue après un redémarrage ou un changement
de mode, des corrections de caméra et du feu de Cocorico, et des améliorations
des listes de mods et de journaux. Les changements propres à Android ou Linux
ne sont pas présentés comme des bénéfices iOS. Les mods natifs restent désactivés
dans le Core intégré ; cette mise à jour ne promet pas l'intégration du Randomizer.

Les 21 fichiers amont adaptés dans NeoStation ont été comparés à leurs versions
pristines précédentes, vérifiées par SHA-256. Quatre ont changé en amont :
`CMakeLists.txt`, `AR.cpp`, `gpu.cpp` et `gpu.hpp`. Leur fusion à trois versions
est sans conflit et conserve les adaptations canoniques NeoStation. Les deux
fichiers SDL adaptés restent identiques. Aucun correctif historique n'est
rejoué par la CI. L'identité du Core indique désormais la version amont.

L'ancien test du SHA pristine de `AR.cpp` est mis à jour parce qu'Aurora remplace
son include `ar.h` par `arq.h`. Les vérifications de libération ARAM, de fermeture,
de reprise, d'audio et d'isolation des fenêtres restent obligatoires. Le contrat
de périmètre autorise explicitement ces fichiers et garde les autres moteurs
et les données utilisateur protégés. Une compilation iOS et une validation sur
iPhone restent nécessaires ; les tests locaux ne prouvent pas le fonctionnement
en jeu sur appareil.

## Mario Kart Pad 0.7.2 : migration à compléter

Référence amont : `2a06769d155a348fd4c0d17c984a20375b7c93be`.
Runtime iOS : `8892a36125681adc8e4e3e6c7d560d83291a84fa`.
La version 0.7.2 corrige notamment l'accélération après retour du second plan et
le démarrage iOS. Son IPA publique ne contient plus le code traduit du jeu.

Le runtime charge `libkartpad_game.dylib` via l'interface de pack ABI 3 et exige
une empreinte d'interface compatible. PadMint construit ce pack sur Mac depuis
le disque personnel PAL RMCP01 révision 0. Un pack 0.7.0 ou 0.7.1 peut être
réutilisé si son empreinte est compatible ; le moteur intégré 0.5.1 ne constitue
pas un tel pack.

Le Core NeoStation actuel enveloppe le binaire officiel 0.5.1 et applique des
adaptations vérifiées pour ses symboles et ses instructions. Remplacer son IPA
par l'application vide 0.7.2 ou changer uniquement le numéro de version ne
produirait pas une mise à jour fonctionnelle. Aucun pack personnel compatible
n'a été fourni dans cette session. L'ancienne identité KartPad reste donc
inchangée jusqu'à l'adaptation du nouveau runtime et à sa validation avec un
pack personnel. Aucun pack ou code traduit du jeu ne doit être publié.

## Cheats : distinguer le fichier TXT du binaire GCT

La capture du signalement montre GMXP70 révision 0, un aperçu GCT contenant
14 lignes et le message expliquant l'absence de titres. L'autre capture montre
un document texte avec GameID, titre du jeu et blocs nommés. Le fichier exact
importé n'est pas disponible : la capture ne démontre pas que ces deux formats
ont été confondus par le parseur.

Le code actuel vérifie l'en-tête et le terminateur binaires GCT avant ce chemin.
Les fichiers TXT/INI nommés passent déjà par le parseur de documents, qui conserve
les titres, les auteurs et les codes multilignes. Un GCT ne permet pas de
retrouver ces noms ; découper chaque ligne casserait les codes à plusieurs lignes.
Les tests existants couvrent les deux chemins ainsi que l'import PNACH d'ARMSX2.
Demander le TXT et le GCT exacts de GMXP70 avant de prétendre corriger ce cas.

Sources :
- https://github.com/TwilitRealm/dusklight/releases/tag/v2.0.3
- https://github.com/chrissotraidis/kartpad/releases/tag/v0.7.2
- https://github.com/chrissotraidis/wiicompiled/blob/8892a36125681adc8e4e3e6c7d560d83291a84fa/runtime/include/game_pack.h
- https://github.com/chrissotraidis/kartpad/blob/2a06769d155a348fd4c0d17c984a20375b7c93be/padmint.json
