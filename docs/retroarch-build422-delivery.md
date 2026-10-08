# Candidate 422 : bibliothèque 419 et liaison RetroArch

Le mainteneur autorise le 8 octobre 2026 l'envoi du commit `3c1e68c` et des
compléments sur `experimental`. La Build 419 devient la référence source,
sans déplacement de `main` ou `backup` et sans reprise de son numéro de build.

Les données existantes ne sont ni réinitialisées ni réparées. Le retour du code
ne supprime pas les doublons déjà persistés, notamment Ports iOS et émulateurs
embarqués. Une réparation éventuelle se traite séparément, après observation.

Le nouveau test sur disque répète les scans, rouvre SQLite puis rescane : un
fichier garde une seule entrée et ses favoris/temps de jeu. Un autre contrôle
préserve deux appartenances légitimes à des playlists dans le cache RetroArch.
Les tests avec la base fournie utilisent exclusivement une copie temporaire.
Ces contrôles ne prouvent pas l'accès aux bookmarks de l'iPhone réel.

Une exception de liaison d'une expression au retour source 419 est documentée :
`resolveRetroArchScanRoot` conserve le chemin littéral fourni par Fichiers.
`trim()` supprimait un espace final valide et rendait le dossier inaccessible.
Le garde de baseline reconstruit exactement cette ancienne expression et
verrouille tous les autres octets de ce fichier, ainsi que les autres sources.

Le protocole vérifié reste `retroarch://library?scheme=neostation`, avec callback
`neostation://retroarch?games=...`, puis `retroarch://game/<filename encodé>`.
Le cœur et le chemin complet viennent de la playlist lue par RetroArch ; aucun
paramètre de cœur inventé n'est envoyé. Une acceptation par iOS est un transfert
de demande, pas la preuve que RetroArch a initialisé son cœur ni démarré le jeu.
Le défaut de réception à froid visible dans la source publique du récepteur
reste une limite à tester avec le binaire TestFlight installé.

## Réutilisation des validations

Le workflow de livraison compare toute la fermeture de sources, tests,
lockfiles, recettes natives et ressources au SHA validé
`af0d539b4b8b3b95fe0434fc1f72c74d7c0b6eca`, run `37781416715`. Il vérifie en
ligne le succès réel du run et de ses étapes. Toute modification hors du delta
explicitement revu bloque cette réutilisation. Les résultats historiques
conservent leur SHA. Les tests des changements se font avant la compilation,
une seule fois pour les deux builds de mesure. Les contrôles des artefacts,
des identités natives et des signatures restent obligatoires à chaque export.

## Mesure et confidentialité

Le run historique 37781416715 (tentative 2) donne des durées observées :
attente Linux 18 min 46 s ; job macOS 21 min 37 s ; compilation Xcode 4 min 42 s ;
suite de régressions 4 min 13 s ; instruction KartPad 2 min 20 s ; préparation
Flutter avec caches 1 min 49 s ; StikJIT 1 min 16 s ; configuration et Pods
46 s ; packaging et contrôles 1 min 36 s. Ce run utilisait déjà les caches SDK
et Pub : il ne constitue pas un build totalement sans cache.

Le nouveau workflow exécute une paire explicitement demandée avec
`[benchmark-build]` : premier build sur des clés de cache nouvelles, second
sur un nouveau runner `macos-15` utilisant exactement l'état du premier.
SDK, Flutter, CocoaPods, CPU/RAM, versions, lockfiles et defines sont consignés.
Les temps Dart/AOT sont produits par l'option prise en charge de Flutter 3.47.2
`PERFORMANCE_MEASUREMENT_FILE`, et Xcode produit son `Build Timing Summary`.
Les temps de tâches natives peuvent se chevaucher : ne pas les additionner
pour les présenter comme des durées murales exclusives.

Il n'y a pas de `flutter clean` systématique. La sortie iOS générée et les
intermédiaires sont réutilisés uniquement à sources/SDK/defines identiques.
La concurrence annule les anciennes livraisons de la même branche. Les moteurs
sont téléchargés depuis leurs artefacts épinglés, vérifiés, jamais reconstruits.
La préparation des interfaces StikJIT manquantes conserve son pin canonique.

Le dépôt est public. Les artefacts de livraison et diagnostics sont chiffrés
pour le destinataire de cette session, et le cache contenant le build AOT est
chiffré/authentifié avec un secret déjà autorisé. Aucune clé privée n'entre dans
le dépôt. Aucune nouvelle release publique n'est créée.

## Signature et installation

Méthode confirmée : SideStore. La CI scelle et vérifie chaque exécutable,
framework et extension avec une signature ad hoc de préparation. Elle vérifie
la conservation des sections de code/données et métadonnées ABI, puis les
signatures sur les octets extraits de l'IPA finale. ARM64, iPhoneOS, ressources,
dépendances, bundle IDs, versions et iOS minimal sont contrôlés.

Cette signature n'est pas une identité Apple avec provisioning d'installation.
SideStore doit appliquer celle du compte du mainteneur et les profils associés
à l'iPhone. La CI existante ne configure aucun certificat Apple ni profil.
Il n'y a donc pas d'export Apple `-exportArchive` attesté : l'IPA SideStore est
exportée du même bundle `Payload` scellé, sans compilation supplémentaire.

L'installation, l'ouverture de RetroArch et le démarrage réel d'un jeu restent
non testés tant qu'aucun iPhone n'est accessible. Les rapports générés et les
mesures effectives accompagnent chaque fichier récupéré ; aucun gain de temps
estimé et aucun succès de jeu déduit du seul lancement d'URL ne sont annoncés.
