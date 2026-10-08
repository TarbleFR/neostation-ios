# Comparaison demandée : Builds 411–412, baseline 419 et réception RetroArch

La comparaison porte sur les sources Git, pas sur une reconstruction supposée
des anciennes IPA. Le run historique Build 411 `37605768644` répond maintenant
404 : son succès et l'identité de son IPA sont consignés dans
`docs/neoplay/BUILD411.md`, mais ne sont pas présentés comme une nouvelle
vérification CI. Les runs Build 412 retenus au SHA `32496cd` comprennent un
packaging échoué et un packaging annulé ; aucun de ces deux runs ne prouve
qu'une IPA Build 412 a été validée.

## NeoStation avant les derniers ajustements

Révisions comparées :

| Référence | Commit |
| --- | --- |
| Build 411, identité historiquement consignée | `8c63c682946b7ad736d5391086016399100c4bd9` |
| Autre candidate Build 411 | `d317c956f36c06588e491a0cfaf18d754f303b76` |
| Première candidate Build 412 | `5786b22a1e931378abd22a2bcc79303f713b72cc` |
| Candidate Build 412 après restauration des artefacts natifs | `32496cd671d04066f7932564b7c489db73f9b174` |
| Baseline de bibliothèque Build 419 | `9e0aca6a34034102b2e6aa083b1588b274b83e5f` |
| IPA 422 réellement produite et mesurée | `00285ba5cfec694d59e1ca2bcf9de31418fd4e1a` |

Les cinq premières références ont les **mêmes blobs Git** pour le service
RetroArch, son appel par `GameLaunchService`, le plugin natif d'accès aux
dossiers, son interface Dart et `lib/main.dart`. Le mécanisme antérieur
construit `Uri(scheme: 'retroarch', host: 'game', pathSegments: [filename])`,
puis appelle `launchUrl` une fois. Le nom provient de l'export RetroArch et
n'est pas consommé au premier lancement. Aucune différence de ces fichiers
entre 411, 412 et 419 n'explique une rupture soudaine du lien.

`pubspec.yaml`, `pubspec.lock`, le générateur de l'hôte iOS et les configurateurs
iOS Dolphin/ARMSX2 sont également identiques entre 411, 412 et 419. Le dossier
`ios/Runner` est généré lors du build ; il n'est pas une ancienne source suivie
par Git que l'on pourrait comparer directement. Le générateur et les
déclarations des schémas `retroarch`/`neostation` sont inchangés.

Le scanner SQL est identique entre 411, 412, 419 et la livraison actuelle :
blob `19a42b9d7c1c0c67fec3d4e14ea7db7003282209`. L'intégration du scanner dans le
provider a le blob `e8a7754f4534a4a58a0a9aa254ef6198e4ece4f0` dans ces quatre
références. Aucun retour à 411–412 de la bibliothèque n'est donc nécessaire
pour retrouver ce code. Aucun historique de données n'est réparé ici.

Les changements après 419 ont introduit un réveil préalable
`retroarch://start`, puis une seconde ouverture depuis l'arrière-plan.
Ce défaut de sender a été retiré : l'IPA 422 envoie directement une seule URL
fonctionnelle pendant que NeoStation est active. Le protocole reste le même.
Les garde-fous et diagnostics ajoutés ne démontrent pas que RetroArch exécute
le jeu : `handoffAccepted` désigne uniquement l'acceptation UIKit.

## Changement trouvé dans RetroArch

Le commit public RetroArch
`630b36bd774c873b73bfaa59183822837dbc9aac`, du 16 septembre 2026,
« Apple: Add support for Xcode 27 », ajoute simultanément
`UIApplicationSceneManifest` et `RetroArchSceneDelegate`. Son parent est
`875549ce5783dfb0f6fb94d0dc5b7fb115dad458`.

Avant ce changement, l'application utilise le delegate historique.
`applicationDidFinishLaunching:` initialise RetroArch, puis UIKit transmet
l'URL à `application:openURL:options:`. Avec les scènes, une première demande
est fournie à `scene:willConnectToSession:options:` dans
`connectionOptions.URLContexts`. Ce nouveau callback crée la fenêtre mais
ne traite pas ces URL. Seul `scene:openURLContexts:` d'une scène existante
transmet les demandes au handler normal.

La classe de scène est **identique octet pour octet** dans le commit qui
l'introduit et dans la source publique examinée
`a7363feb909391c3217b91c30e81547e8208d6d5`. Les identités des fichiers entiers
sont vérifiées par hash de blob Git avant le contrôle.

Le schéma enregistré reste `retroarch`. Les routes `game/<filename>`,
`library?scheme=...` et `topshelf?path=...&core_path=...` existent encore dans
le handler. Modifier le contenu de l'URL ne force pas la scène à transmettre
une URL initiale qu'elle ignore. La route explicite `topshelf` ne constitue
donc pas à elle seule un correctif du premier lancement.

Le mainteneur identifie son application comme TestFlight 780 du 8 octobre
2026 ; les captures montrent la version 1.22.2. Aucun IPA RetroArch, hash de
son exécutable, note TestFlight contenant le commit ou journal du récepteur
n'a été reçu. La présence de cette classe exacte **dans ce binaire installé**
n'est pas attestée. La régression publique et sa concordance avec les vidéos
sont établies séparément de cette attribution encore à confirmer.

## Contrôle ciblé et correctif du récepteur

Le nouveau contrôle `tools/test_retroarch_source_receiver.py` télécharge des
fichiers publics à des commits fixes et vérifie leurs blobs. Il compile la
classe Objective-C de scène **sans modifier son corps**. Un observer séparé
consigne les options initiales réellement fournies par UIKit. Le reste de
RetroArch est remplacé par un enregistreur de réception et une fenêtre :
aucune bibliothèque de jeux ni aucun cœur ne sont exécutés.

Trois configurations sont confrontées aux trois mêmes routes, d'abord à
froid puis à chaud : delegate historique de contrôle, classe publique avec
omission, même classe après application du patch revu. Le sender utilise
`RetroArchURLHandoff.swift` de production. Les résultats des vrais appels
UIKit sont lus dans les deux conteneurs de test ; aucune acceptation n'est
simulée. La route avec chemin/cœur sert à tester son acheminement, pas la
validité de ces ressources sur un appareil.

Le patch `upstream/retroarch-initial-scene-url.patch` est vérifié par
`git apply --check`, puis réellement appliqué à la source complète épinglée
avant extraction/compilation du contrôle corrigé. Il transmet une fois les
URL initiales au handler existant après création de la scène. Les cœurs,
playlists, chemins, schéma public et code de parsing restent inchangés.

Le run dédié `37857669052`, commit
`3c70b5f4adb80232d3c50d0b648520c7db5afe2c`, a terminé avec succès.
Les trois séquences XCTest ont réussi sur iOS Simulator 18.5, Xcode 16.4
(`16F6`). Chaque séquence réalise six appels UIKit : trois routes, chacune
demandée à froid puis à chaud. Les **18 demandes sont acceptées par iOS**.

| Récepteur contrôlé | URL froides reçues / 3 | URL chaudes reçues / 3 |
| --- | ---: | ---: |
| Delegate historique de contrôle | 3 | 3 |
| Classe publique exacte, sans correctif | 0 | 3 |
| Même classe après application du correctif | 3 | 3 |

Les trois URL froides sont présentes dans les options initiales du récepteur
public non corrigé. Elles n'atteignent pas son handler. Le correctif les y
transmet une seule fois, y compris pour la route à chemin/cœur explicites.
La classe exacte et la variante corrigée compilent en Objective-C/ARC ; le
contrôle historique remplace le moteur et ne recompile pas l'ancien RetroArch.
Le contrôle complet et la construction des petites apps prennent 604 secondes
sur le runner ; ce temps n'est pas une mesure de build NeoStation.

L'artefact chiffré `11584224825` a été téléchargé et son SHA-256 vérifié :
`df326c40a8169af5b7070f180be2bfc49e36ee7a9d03233e571f22ec74000b34`.
Les résultats JSON déchiffrés sont examinés séparément des assertions du run.
`gameExecutionValidated=false` demeure explicite.

Les résultats de bibliothèque et moteurs sont réutilisés à entrées produit
strictement identiques ; leurs tests ne sont pas relancés. Les jobs de
packaging IPA ont été ignorés dans ce commit de diagnostic.

## Limite d'application et trajectoires concrètes

Une IPA NeoStation ne peut pas remplacer le code du delegate du RetroArch
TestFlight installé. Le correctif est prêt pour le **récepteur RetroArch**,
et n'est pas présenté comme installé par une mise à jour de NeoStation.
Si le TestFlight utilise cette classe, aucune variante de la route URL directe
ne répare l'omission initiale. Cette limite ne signifie pas que toutes les
autres intégrations seraient impossibles.

| Voie examinée | Ce qu'elle permet | Condition ou limite réelle |
| --- | --- | --- |
| Correctif du récepteur RetroArch | Conserver le lancement direct à froid et à chaud | Il doit être inclus dans une nouvelle distribution RetroArch ; NeoStation ne modifie pas un TestFlight tiers. |
| Retour à une distribution RetroArch compatible | Revenir au récepteur qui fonctionnait, tout en gardant la bibliothèque NeoStation 419 | La révision antérieure et sa disponibilité TestFlight ne sont pas connues ; aucun remplacement ni effacement n'est effectué. |
| Frontend RetroArch corrigé installé par SideStore | Contrôler le delegate sans reconstruire tous les moteurs | Nécessite une trajectoire d'installation, les cores précompilés exacts et la conservation des données. Deux apps déclarant le même schéma rendent le destinataire indéterminé ; un simple second IPA n'est pas une solution validée. |
| Action RetroArch dans Raccourcis | Appeler `PlayGameIntent` et `cocoa_launch_game_by_filename` par une voie distincte des URL de scène | Nécessite un raccourci installé et un jeu résolu dans son paramètre `GameEntity`. Ce paramètre n'est pas le `gameId` exporté ; la recherche par texte peut être ambiguë. Aucun raccourci de ce type ni résultat à froid n'est attesté ici. |
| Commandes réseau RetroArch | Ouvrir l'app, attendre une réponse `VERSION`, puis envoyer `LOAD_CONTENT <core path>\|<content path>` | Le build public iOS compile `HAVE_NETWORK_CMD`, mais l'interface est désactivée par défaut. Activation et chemin de config doivent être établis sur le TestFlight. Le cœur doit avoir son chemin réel : ce loader iOS développe le chemin du contenu, pas celui du cœur. |

L'interface réseau standard est UDP, port par défaut 55355. Le code examiné
dispose de `LIST_CORES`, `GET_STATUS` et `LOAD_CONTENT`. Il ne faut pas lui
attribuer l'accusé de chargement différé des interfaces *structured* : le
constructeur UDP laisse ce drapeau à zéro. Une réception UDP ou un succès
`UIApplication.open` ne prouve pas le démarrage d'un jeu. Cette voie demanderait
une observation de l'état réel de RetroArch et une validation iPhone.

La capture fournie indique un enregistrement vers
`~/Documents/RetroArch/config/retroarch.cfg`, mais ce fichier de configuration
n'est pas dans les pièces reçues. `playlists.zip` contient 244 membres et
aucun `.cfg`, IPA ou journal RetroArch. Aucun réglage de cette application
n'est modifié silencieusement pour transformer une hypothèse en livraison.

## Décision pour cette intervention

Conserver le produit NeoStation de l'IPA 422, la bibliothèque 419 et les moteurs.
Ne pas produire une nouvelle IPA contenant seulement un autre format d'URL
dont la demande serait encore perdue avant lecture. Livrer les preuves et le
correctif du récepteur, avec la portée exacte du blocage. Les échecs à chaud
signalés ne sont pas déclarés résolus par ce correctif à froid.

Références primaires :

- https://github.com/libretro/RetroArch/commit/630b36bd774c873b73bfaa59183822837dbc9aac
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/ui/drivers/ui_cocoatouch.m
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/pkg/apple/AppIntents/RetroArchAppShortcuts.swift
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/command.c
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/config.def.h
- https://docs.libretro.com/development/retroarch/compilation/ios/
- https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app
- https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:open:options:)
- https://support.apple.com/guide/shortcuts/apd624386f42/ios
