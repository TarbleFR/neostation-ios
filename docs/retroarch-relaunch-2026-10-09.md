# Relancement RetroArch : observation du 9 octobre 2026

Le mainteneur confirme la Build 422 installée, l'absence actuelle de doublons,
et la réussite d'un premier jeu après synchronisation. Il signale aussi des
échecs intermittents même en laissant RetroArch en arrière-plan : ce dernier
cas reste à identifier et n'est pas déclaré corrigé par la seule piste à froid.

La première vidéo montre le démarrage réel de 007 avec mGBA vers 64–69 s,
puis la fermeture de la carte RetroArch vers 70 s. Le relancement affiche son
menu sans cœur. La seconde montre l'écran de démarrage de RetroArch vers
4,5 s, puis le menu ; la seconde demande de 90 Minutes réussit sans nouvelle
synchronisation vers 14 s. ActRaiser démarre ensuite avec Snes9x. Ces images
confirment des démarrages effectifs sur cet appareil, pas la fiabilité générale
ni l'identité du code exact de RetroArch TestFlight 1.22.2.

Les fichiers complémentaires de la même session permettent maintenant de
corréler la seconde vidéo : à 22:26:42.132107 UTC, puis 22:26:50.417479 UTC,
NeoStation envoie exactement le même lien `retroarch://game/90%20Minutes%20-%20European%20Prime%20Goal%20(Europe).sfc`.
Les deux demandes ont le statut `handoffAccepted`. Le premier essai filmé reste
au menu ; le second démarre sans resynchronisation. La demande suivante
d'ActRaiser, à 22:27:01.371226 UTC, démarre également dans la vidéo.

Au total, le journal complémentaire contient 42 demandes RetroArch, toutes
acceptées par iOS, et 18 paires successives du même jeu avec des URL identiques.
Cela ne constitue pas 42 démarrages de jeux. Le message générique du frontend
`Game started` ne vient pas d'un accusé de réception RetroArch. De même,
`Emulator process not detected... Ending session` clôt le suivi de session
NeoStation au retour au premier plan ; ce chemin iOS n'envoie aucune fermeture
au processus RetroArch.

Une seule réponse de synchronisation apparaît dans ce journal, à
22:02:53.879911 UTC : 4 842 jeux exportés. Les demandes ultérieures expirent
sans callback. Le diagnostic le plus récent garde 19 053 clés de cache : ce
sont des alias de recherche, pas 19 053 jeux distincts. Les anciennes données
de synchronisation ne sont donc pas consommées par le premier lancement.

Une copie de la base complémentaire, avec ses WAL et SHM correspondants, a été
ouverte en lecture seule : `quick_check=ok`, 4 853 lignes `user_roms`, aucun
chemin exact dupliqué et aucun chemin nul. Les SHA-256 des trois originaux sont
inchangés. Ce contrôle ne mesure pas les appartenances aux playlists ni tous
les doublons historiques entre sources. Aucune réparation n'est appliquée.

Le cache NeoStation n'est pas consommé au lancement. Un contrôle supplémentaire
vérifie quatre demandes successives identiques, dont un rejet simulé, sans
nouvelle synchronisation : même URL encodée, métadonnées conservées et aucune
modification SQLite. Ce contrôle du sender ne simule pas l'exécution du cœur.

La source publique RetroArch `a7363feb909391c3217b91c30e81547e8208d6d5`
ignore `connectionOptions.URLContexts` dans `scene:willConnectToSession:options:`.
Le callback `scene:openURLContexts:` traite uniquement une scène déjà créée.
La perte de la première demande à froid est donc confirmée dans cette source,
et correspond au scénario filmé ; les erreurs à chaud ne s'en déduisent pas.

Le patch `upstream/retroarch-initial-scene-url.patch` rejoue les URL initiales
une seule fois, après construction de la scène, par le handler normal. Il
conserve le protocole, les playlists, les chemins et les cœurs. Il est préparé
pour **RetroArch**, et n'est pas appliqué à l'IPA NeoStation ni au TestFlight
installé. Il ne constitue pas à lui seul une correction des échecs à chaud.

Le contrôle UIKit compare deux retours à chaud du même lien, puis une fermeture
du récepteur suivie d'une troisième demande. Il utilise le sender de production
et un récepteur synthétique, d'abord avec l'omission publique, puis avec le
rejeu proposé. Les vrais appels UIKit sont observés ; aucun résultat de jeu
RetroArch ne peut être déduit du résultat de cette fixture.

Le run `37854166989`, commit `0d797b127f3e09d453a58bc6a7883c345bdb9a44`,
a terminé avec succès. Le nouveau test Dart de demandes successives a réussi,
ainsi que son analyse. Sur iOS Simulator 18.5 avec Xcode 16.4, les deux séquences
UIKit ont réussi : deux livraisons à chaud puis zéro livraison à froid pour le
récepteur reproduisant l'omission ; deux livraisons à chaud puis une livraison
à froid pour le récepteur avec rejeu. Les trois demandes sont acceptées par
iOS dans les deux séquences ; la dernière URL est bien présente dans les options
de connexion. L'extrait Objective-C du patch a également passé la compilation
syntaxique ARM64 iPhoneOS, avec ARC et sans ARC. Aucun cœur RetroArch n'est
compilé ou exécuté dans ce contrôle.

Les anciennes validations et l'IPA 422 sont réutilisées à entrées produit
strictement identiques. Cette mise à jour documentaire ne demande ni nouveau
test ni nouvelle compilation.

La bibliothèque 419 et tous les moteurs de NeoStation sont inchangés. Aucun
nouveau build IPA n'est lancé pour ces seuls diagnostics/tests. La livraison
422 reste attachée au commit `00285ba5cfec694d59e1ca2bcf9de31418fd4e1a`
et au run `37847695065`, indépendamment du commit de cette note.

Pour établir un échec à chaud restant, il manque encore le journal de
réception/chargement RetroArch du même essai : les diagnostics NeoStation sont
désormais disponibles. Une acceptation `UIApplication.open` ne signifie pas que RetroArch a
accepté le contenu, trouvé le cœur ou démarré le jeu. Aucun cache-buster,
nouveau paramètre, second envoi automatique ou réparation de données n'est
introduit pour masquer cette distinction.

Références primaires :
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/ui/drivers/ui_cocoatouch.m
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/ui/drivers/cocoa/cocoa_common.m
- https://developer.apple.com/documentation/uikit/uiscene/connectionoptions
