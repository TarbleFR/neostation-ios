# Retour au parcours de bibliothèque Build 419 et liaison RetroArch

La demande du mainteneur remplace le chantier de réparation : revenir au code
antérieur aux doublons, puis travailler uniquement sur la lecture et le lancement
RetroArch TestFlight. **Aucune migration, fusion ou réparation de base n'est
appliquée. Aucune IPA n'a été compilée pendant ce retour.**

## Référence rétablie

Build 419 : `9e0aca6a34034102b2e6aa083b1588b274b83e5f`.
Le commit `12fb62f` conserve ces sources et les ajouts NeoPlay 0.8.0.
Les dix fichiers du manifeste `retroarch-baseline-manifest.json` sont identiques
octet pour octet à ceux de Build 419 : scanner, service SQLite, providers,
répertoires, repositories, affichage des systèmes et démarrage.
Cela concerne aussi GameCube/Wii via DolphiniOS, PS2 et Ports embarqués.
Les 130 fichiers natifs contrôlés conservent leur contenu antérieur à ce retour.
Le manifeste de packaging `native/import-memory-candidate.json` reste inchangé.

La restauration automatique de lignes virtuelles RetroArch et la conservation
globale de sources non parcourues ajoutées dans Build 421 sont retirées.
Les changements transversaux d'isolation SQLite ajoutés après l'audit sont
retirés aussi. Les modules de réparation ne font plus partie des sources
exécutables. Les anciens tests et sources concernés sont conservés comme texte
dans `docs/audit/build421-retired/`, et remplacés dans le contrôle de liaison par
un test qui exige que les callbacks répétés ne modifient aucune ligne de jeu.

La base envoyée par le mainteneur reste intacte. Revenir au code précédent ne
reconstitue pas une ancienne version des données déjà enregistrées sur iPhone.
Il ne faut pas présenter ce retour comme une preuve de disparition des doublons
déjà stockés. Le scanner retrouvé conserve son comportement antérieur de
nettoyage des fichiers absents ; aucune réparation supplémentaire n'y est ajoutée.

## Comparaison du protocole

Sources officielles examinées :

- [ajout du protocole en juillet, `76796ee`](https://github.com/libretro/RetroArch/blob/76796ee6d0e41abd44fd73dcfaa71e9c7787fb42/ui/drivers/ui_cocoatouch.m) ;
- [révision du 8 octobre à 10:07 UTC, `a699800`](https://github.com/libretro/RetroArch/blob/a69980050e2d99c8877a84bf7e516d2bd5353f15/ui/drivers/ui_cocoatouch.m) ;
- [révision du 8 octobre à 18:43 UTC, `a7363fe`](https://github.com/libretro/RetroArch/blob/a7363feb909391c3217b91c30e81547e8208d6d5/ui/drivers/ui_cocoatouch.m).

Les trois dispatchers acceptent les mêmes commandes :

| Action | Commande vérifiée |
| --- | --- |
| Demander les playlists exportées | `retroarch://library?scheme=neostation` |
| Recevoir l'export JSON base64url | `neostation://retroarch?games=...` |
| Sélectionner le contenu exporté | `retroarch://game/<filename>` |

Le nom vient de `filename`/`titleId`, pas d'un UUID de conteneur NeoStation.
Le numéro TestFlight 780 et la version 1.22.2 ont été fournis/observés, mais
aucune donnée fournie n'établit son SHA exact. L'examen des sources publiques ne
prouve donc pas à lui seul l'identité du binaire TestFlight installé.

Le `launch_debug.txt` fourni trouve bien 007 dans l'export ; cette tentative
n'est pas un échec de recherche de bibliothèque. Le mainteneur confirme que
le même jeu démarre directement dans RetroArch.

## Défaut d'envoi et changement conservé

Dans `e008bcd` (Build 420), `RetroArchURLHandoff.start()` ouvrait
`retroarch://start`, attendait une seconde, puis envoyait la véritable commande.
Le premier lien place NeoStation en arrière-plan avant le second.
Les preuves UIKit antérieures reproduisent ce refus avec des applications de
test : seule la commande `start` est reçue ; la commande fonctionnelle est
refusée. Une commande fonctionnelle directe est reçue une seule fois lorsque
le récepteur dispose déjà d'une scène. Le retour de synchronisation est reçu
dans ce cas. Ces résultats concernent le transport, pas un cœur RetroArch.

La candidate conserve uniquement l'envoi fonctionnel direct, une attente bornée
du premier plan, la réception des callbacks avant/après l'installation du
listener, les diagnostics d'erreur et les libellés des douze langues.
La synchronisation réussit uniquement après un export valide. Elle met à jour
le cache de lancement puis utilise le scanner précédent ; elle n'insère aucune
ligne virtuelle dans la bibliothèque. Le lancement n'impose pas de nouvelle
synchronisation et ne renvoie jamais une fausse erreur « entrée introuvable »
pour un refus de transport.

## Vérifications réellement exécutées

- 27 tests Flutter ciblés : décodage, cache, callbacks répétés/simultanés,
  erreur/expiration, noms de contenus et archives, double lancement, isolation
  ARMSX2, comportement du scanner précédent et douze traductions.
- 3 contrôles Python : référence Build 419 exacte, identité des 130 fichiers
  natifs et absence des modules de réparation dans les sources exécutables.
- Analyse Dart : aucune erreur ni avertissement ; quatre informations de lint
  non bloquantes, notamment hors du parcours modifié.
- 1 test supplémentaire sur les pièces réelles : les 4 842 entrées de playlists
  sont décodées ; deux exports répétés et deux simultanés ne changent aucune des
  8 923 lignes de jeu de la copie ; 007 sélectionne une seule URL contenant le
  nom exact attendu. Le transport est simulé : ce test ne démontre ni l'accès
  aux dossiers sur iPhone ni le démarrage d'un cœur. Les écritures de diagnostics
  natives ne sont pas vérifiées par ce banc Flutter Linux.

Le contrôle CI de liaison compile seulement les tests Swift du transport et
analyse sa syntaxe iOS. Le banc UIKit lent est retiré de ses relances automatiques.
Aucune compilation de moteur ni nouvelle IPA n'a été lancée ici.

## Limite iPhone et retour arrière

Dans les sources RetroArch examinées, `scene:willConnectToSession:options:` ne
transmet pas les URL initiales de `connectionOptions`. Le test UIKit antérieur
ne reçoit donc aucune commande au démarrage à froid malgré l'acceptation iOS.
Cette limite n'est pas résolue par une nouvelle URL inventée ou un délai ajouté
dans NeoStation. La réception chaude est établie par le banc ; la réception
avec TestFlight 780, la lecture visible des bibliothèques et le démarrage réel
d'un cœur doivent encore être vérifiés sur iPhone.

Le point de départ de ce retour est
`b14ab5bfe27f912238082e0b0e242789087ec4d9`. Le retour est conservé dans un commit
unique, réversible avec `git revert <SHA-du-retour>` ; aucun déplacement de
`main`, `backup` ni réécriture de l'historique n'est nécessaire.
