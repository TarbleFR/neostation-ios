# NeoStation 423 — enregistrement des dossiers RetroArch

Référence produit : NeoStation 422, `00285ba5cfec694d59e1ca2bcf9de31418fd4e1a`.
Le mainteneur confirme les bibliothèques visibles et les lancements avec RetroArch en arrière-plan dans cette référence.

## Défaut établi

Le journal fourni indique `romFolders=7` et plusieurs anciens conteneurs introuvables. La table `user_rom_folders` du fichier fourni contient sept chemins. Pourtant `SqliteConfigProvider.addRomFolder` s'arrêtait sans erreur à partir de cinq racines. Le bouton de liaison appelait cette méthode puis affichait un succès sans vérifier son effet. Une nouvelle sélection ne modifiait donc pas les racines du scan lorsque le nouveau chemin était absent. La synchronisation RetroArch ne répare pas cette table : elle alimente le cache de lancement puis déclenche le scanner existant.

Ceci établit le défaut de changement de dossier sur cet état de configuration. Aucun journal plus récent de l'iPhone n'a été reçu pour attester que c'est l'unique cause de l'écran vide actuel. Un dossier racine peut contenir plusieurs consoles ; les sept entrées sont des racines enregistrées, pas une mesure du nombre de consoles.

## Correction ciblée

- Retrait des deux plafonds de cinq dossiers : fournisseur de configuration et sélecteur générique.
- La nouvelle configuration en mémoire n'est validée qu'après sa persistance réussie.
- La liaison externe vérifie que le dossier est effectivement enregistré avant de déclarer son succès.
- Aucun changement du parsing RetroArch, de son cache, des URL, des signets natifs, du scanner de ROM, des fichiers de jeux ou des moteurs. Aucun effacement de données ni réparation de la base fournie.

La CI doit reproduire le refus de la huitième racine sur le code 422, puis valider la candidate : ajout avec sept anciennes racines, scan d'un vrai fichier sous un dossier Unicode avec espace final, préservation du favori et du temps de jeu après répétition, enregistrement de 130 racines sans plafond et absence de faux succès après échec SQLite. Le nombre 130 est une taille de test, pas une limite du produit.

## Livraison et limites

Cette candidate produit une IPA NeoStation 423 avec les moteurs natifs déjà validés, sans reconstruire RetroArch. Les gardes conservent l'identité de tous les autres octets du scanner et des sources natives. Les entrées Swift inchangées réutilisent leur validation antérieure. Un seul build Release est demandé ; aucun benchmark supplémentaire.

Le défaut de réception du lien à froid dans la scène publique RetroArch reste distinct. Ce correctif ne modifie pas le TestFlight installé et ne prouve pas un lancement à froid dans celui-ci. Le lancement à chaud de la 422 est conservé par identité de ses sources. Installation et résultat final sur l'iPhone restent à vérifier après livraison.
