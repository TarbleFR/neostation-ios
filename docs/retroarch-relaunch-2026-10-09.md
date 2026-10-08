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

La bibliothèque 419 et tous les moteurs de NeoStation sont inchangés. Aucun
nouveau build IPA n'est lancé pour ces seuls diagnostics/tests. La livraison
422 reste attachée au commit `00285ba5cfec694d59e1ca2bcf9de31418fd4e1a`
et au run `37847695065`, indépendamment du commit de cette note.

Pour établir un échec à chaud restant, il faut comparer les diagnostics de
la demande NeoStation et le journal de réception/chargement RetroArch du même
essai. Une acceptation `UIApplication.open` ne signifie pas que RetroArch a
accepté le contenu, trouvé le cœur ou démarré le jeu. Aucun cache-buster,
nouveau paramètre, second envoi automatique ou réparation de données n'est
introduit pour masquer cette distinction.

Références primaires :
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/ui/drivers/ui_cocoatouch.m
- https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/ui/drivers/cocoa/cocoa_common.m
- https://developer.apple.com/documentation/uikit/uiscene/connectionoptions
