# Build 365 — import de cheats en lot

Candidate privée sur experimental. Aucun changement au JIT, aux cores, aux
réglages d’affichage ni au cycle de vie des émulateurs.

## Utilisation

Dans le menu Cheats de Dolphin ou ARMSX2, « Importer un fichier » ouvre
Fichiers. Le fichier entier est analysé avant toute écriture. La liste affiche
chaque titre, auteur lorsqu’il est présent, format et nombre de lignes.
« Importer les N cheats » enregistre le lot en une opération ; aucune saisie
d’un titre ou d’une ligne pour chaque cheat n’est nécessaire.

Les nouvelles entrées sont désactivées. Leur activation et leur suppression
restent individuelles dans les listes existantes. Les doublons strictement
identiques avec le même titre sont ignorés. Un même titre associé à un code
différent ou non vérifiable bloque l’import sans écraser les codes existants.

## Formats et limites

Dolphin : INI avec sections Gecko/ActionReplay, TXT avec titres suivis de leurs
blocs de code, exports WiiRD/Ocarina avec GameID, fichiers AR/Gecko textuels.
ARMSX2 : PNACH avec sections nommées ; les titres en commentaires PNACH sont
reconnus lorsqu’ils sont séparés et précèdent des lignes patch.

Les blocs multilignes restent groupés : une ligne vide entre deux lignes de
code ne crée pas un nouveau cheat. Aucune adresse ou valeur n’est inventée.
Les TXT ambigus, codes avec variables non remplacées et fichiers malformés
peuvent nécessiter une correction du fichier source. L’application ne convertit
pas un code PS2 en Gecko ou réciproquement.

Un GCT binaire ne contient pas les titres originaux : il reste une seule entrée
combinée et un avertissement l’indique. Utiliser le TXT/INI source pour importer
plusieurs cheats nommés séparément. UTF-8 et UTF-16 sont pris en charge.
Limites : 256 Kio par fichier, 512 entrées, 8192 lignes de code et 127 lignes
chiffrées Action Replay par bloc. Un bloc invalide ou vide annule l’import
entier ; le numéro de ligne est affiché. Les réglages graphiques et listes
d’activation présents dans un INI importé ne sont pas appliqués.

## Validation automatisée

Les tests ajoutés emploient des fixtures synthétiques de 50 cheats à deux
lignes, des blocs AR de cinq lignes, du UTF-16, des titres multilingues, les
conflits, les réimports et la suppression d’une seule entrée d’un lot.
Les tests UIKit exécutent les deux éditeurs réels et leur callback de lecture
de document ; le stockage Foundation est testé séparément avec les fichiers
réels et l’écriture atomique. Le JIT et les cores sont comparés à la Build 364.
Le contenu final de l’IPA doit contenir les deux éditeurs et l’action directe.

Ces contrôles ne prouvent pas l’effet des codes dans un jeu. Le fichier exact
du testeur n’a pas été fourni : son essai reste nécessaire pour confirmer son
format et le résultat sur appareil. Ne pas publier de fichiers de jumelage.
