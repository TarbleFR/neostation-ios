# Consignes permanentes — stabilité NeoStation iOS

Ces règles expriment les exigences du mainteneur du 18 septembre 2026 et s'appliquent à toute intervention sur ce dépôt.

## Une seule référence de travail

- Le mainteneur adopte la Build 419 comme nouvelle baseline le 8 octobre 2026 : référence source `9e0aca6a34034102b2e6aa083b1588b274b83e5f`, notamment pour le comportement de bibliothèque. Ne pas réutiliser le numéro 419 pour une nouvelle livraison. Aucun SHA d'IPA Build 419 n'est attesté ici. La Build 350 reste uniquement le donneur natif historiquement vérifié (`5e6dc00b35b7bb7847c24198d9f4b08ade8ed9a0`, run `36323843067`, IPA SHA-256 `e1017b96842ec970be3ed0cd981083ee945d069cf76e689a4ca3c81339299b46`). Ne pas modifier `main`, `backup` ou les références Git de baseline sans demande explicite.
- Travailler sur une seule version candidate clairement identifiée pendant le cycle de correction. Chaque modification crée naturellement un nouveau SHA : consigner ce SHA exact, ne pas mélanger des binaires ou des résultats de tests provenant de révisions différentes.
- Ne jamais réutiliser le nom d'un artefact pour faire passer une autre révision pour celle déjà testée. Associer version, SHA, entrées natives et résultats de validation.

## Branche de travail unique — dernière consigne du mainteneur du 9 octobre 2026

- À la demande du mainteneur, tous les assistants, y compris ChatGPT/Codex et Claude, travaillent désormais uniquement sur la branche `Claude` (ancienne `experimental`, renommée au commit `0bf904a`, source de la Build 423). Toutes les modifications, commits, CI et builds de travail se font sur cette branche. Cette consigne remplace la réservation précédente de cette branche à l'assistant Claude.
- Les branches de travail `ChatGPT` et `neoplay-v2-frames` ont été supprimées ; aucune branche NeoSwap n'était présente. Ne pas recréer de branches de travail ChatGPT, NeoSwap ou NeoPlay sans demande explicite du mainteneur. La règle existante exigeant une demande explicite pour modifier `main`, `backup` ou les références de baseline reste applicable.
- Les workflows déclenchés par push filtrent encore `experimental` : sur `Claude`, une build ou un contrôle se lance par `workflow_dispatch` avec `--ref Claude`.

## Décision du mainteneur — lancement RetroArch, 9 octobre 2026 après-midi

- La bibliothèque s'affiche avec la Build 423. Le défaut restant : un jeu lancé depuis NeoStation ouvre RetroArch sans le démarrer quand RetroArch était fermé.
- Exigence : l'utilisateur ne fait aucune manipulation (ni réglage RetroArch, ni raccourci) ; il lance simplement son jeu depuis NeoStation. La voie des commandes réseau de RetroArch, désactivées par défaut, est donc écartée. Les essais 424 et 425 ont été annulés avant toute IPA et retirés ; les sources produit restent celles de la 423.
- Démontré : `RetroArchSceneDelegate` ignore l'URL qui démarre RetroArch (de `630b36bd` à `master` `df16ef1`) ; iOS refuse un second lien envoyé dans le même passage au premier plan (run `37927541605`) ; commandes réseau et serveur MCP de RetroArch sont désactivés par défaut. Aucun changement de NeoStation seul ne démarre le jeu à froid sans réglage : le correctif appartient au récepteur RetroArch (`docs/upstream/retroarch-initial-scene-url.patch`).

## Décision du mainteneur — moteur libretro intégré, 9 octobre 2026 soir

- Le mainteneur demande toutes les phases de `docs/retroarch-integre-architecture.md` jusqu'à une IPA de test, avant toute validation des licences. Les licences des cœurs (dont snes9x, genesis_plus_gx, genesis_plus_gx_wide, fbneo et picodrive) seront revues après les tests sur iPhone.
- Le moteur est le pont `packages/libretro_internal_bridge` : hôte libretro natif, session plein écran, menu en jeu, sauvegardes, états, triches et RetroAchievements. Les cœurs officiels du buildbot sont empaquetés par `.github/workflows/libretro-cores.yml` (artefact `LibretroCores-<sha>`), copiés après `xcodebuild` et chargés seulement au lancement d'un jeu.
- Aucun des dix fichiers de bibliothèque verrouillés sur la Build 419 n'est modifié : les jeux importés vont dans `Documents/roms/<système>`, enregistré comme dossier de bibliothèque, et les ROM des dossiers déjà liés sont lues sur place.
- La route `retroarch://` reste pour les systèmes sans cœur intégré, pour les jeux connus seulement de la bibliothèque RetroArch et pour les jeux réglés sur « Application RetroArch (externe) ».

## Décisions du mainteneur — bibliothèques, 10 octobre 2026

- Les jeux importés vont dans une bibliothèque existante de l’utilisateur, jamais dans une seconde bibliothèque créée à côté : choix parmi les dossiers enregistrés accessibles (direct s’il n’y en a qu’un) ; le dossier `roms` de NeoStation n’est utilisé que si aucune bibliothèque n’est enregistrée ; un jeu déjà présent (même nom, même taille) n’est pas recopié.
- Première ouverture iOS : NeoStation propose de créer un dossier par console dans `NeoStation › roms` (recommandé, sans autre action), de **déplacer** une bibliothèque existante dans ce dossier (l’autre dossier n’est ensuite plus utilisé), ou de lier un dossier sans le déplacer. Les mêmes actions sont dans Réglages › Dossiers › Consoles intégrées.
- Autorisation explicite de modifier le démarrage (`lib/main.dart`, verrouillé sur la 419) : les dossiers enregistrés introuvables après le déplacement d’un conteneur iOS sont retrouvés au même endroit du conteneur actuel (blocs `LIBRARY_RELOCATION_*`, exception documentée dans `test/retroarch_baseline_scope_test.py`). Aucun fichier de jeu n’est déplacé, aucune ligne de jeu n’est réécrite. Voir `docs/library-folders-2026-10-10.md`.

## Précision du mainteneur — 9 octobre 2026, 13 h

- L'état fonctionnel confirmé est NeoStation Build 422 : bibliothèque visible et lancement RetroArch lorsque l'application externe reste en arrière-plan. Conserver ces sources de lancement/synchronisation ; ne pas prendre le récepteur autonome 781 pour une mise à jour NeoStation.
- Aucun plafond arbitraire du nombre de dossiers de ROM n'est souhaité. La liaison doit enregistrer chaque dossier demandé et permettre son scan. La limite silencieuse de cinq racines a été retrouvée alors que la base fournie en contient sept ; le correctif 423 retire uniquement ce plafond et empêche d'afficher un succès d'enregistrement après un échec de persistance. Le scanner lui-même, les moteurs, la base et les métadonnées de jeux ne font l'objet d'aucune migration.

## Corriger avant de compiler

- Le retour demandé au comportement de bibliothèque Build 419 est prioritaire : aucune nouvelle migration, réparation automatique, remise à zéro ou dissimulation de doublons. Une réparation de données persistées se documente séparément et ne s'applique pas à cette livraison. Corriger uniquement la liaison RetroArch établie et distinguer demande envoyée, application ouverte et jeu effectivement démarré.
- Ne plus superposer les correctifs. Les sources canoniques suivies par Git doivent contenir directement les corrections. La CI ne doit pas rejouer une succession de patches historiques VPN, RPCS3 ou Dolphin pour fabriquer des sources différentes de celles examinées.
- La migration des anciennes couches doit être une opération ponctuelle de mise à plat des sources, revue et commitée, jamais une nouvelle étape cachée exécutée à chaque compilation.
- Ne pas reconstruire ni modifier des cœurs, helpers JIT, scripts de débogage ou réglages d'émulation sans lien établi avec le défaut traité. Conserver et vérifier leurs identités lorsqu'ils doivent rester inchangés.

## Empêcher le retour des régressions

- Consigne explicite du 8 octobre 2026 : ne pas répéter pendant la compilation les tests déjà réussis lorsque leurs entrées sont inchangées. Réutiliser les résultats en conservant SHA testé, run, outils, dépendances et comparaison des entrées ; ne jamais les présenter comme exécutés à nouveau. Relancer les tests concernés par une modification, y compris les dépendances transitives. Sans preuve de succès et d'identité des entrées, la réutilisation est refusée.
- Réutiliser les moteurs, helpers et artefacts validés par leur identité ; ne reconstruire que les éléments modifiés ou les interfaces de compilation réellement manquantes. Mesurer les temps observés et les restaurations/sauvegardes de cache ; préserver Release et les contrôles de signature. L'installation habituelle du mainteneur est SideStore, confirmée le 8 octobre 2026 : une signature ad hoc de préparation ne remplace pas la signature Apple et le provisioning appliqués par SideStore.

- Chaque défaut corrigé doit avoir une vérification de non-régression appropriée. Préférer des tests de comportement aux seules recherches de chaînes dans le code.
- Couvrir notamment : premier lancement et relancement ; alternance DolphiniOS/RPCS3 ; échec de route puis récupération ; absence de double lancement ; expiration et callbacks tardifs ; retour au premier plan ; fermeture de la seule fenêtre appartenant au lancement ; conservation de l'erreur technique réelle.
- Séparer strictement disponibilité TCP, authentification RemotePairing, état du helper, attachement au PID attendu, préparation mémoire et réussite effective du JIT. Aucun de ces états ne doit être déduit de la seule présence d'une route ou d'un succès antérieur.
- Bloquer la compilation candidate lorsque l'analyse ou les tests obligatoires échouent. Ne pas supprimer un test ni affaiblir une assertion pour obtenir artificiellement un résultat vert ; remplacer un contrat retiré par le test du nouveau comportement et expliquer ce changement.
- Ne pas altérer les sauvegardes, bibliothèques, firmware, caches ou fichiers de pairing comme moyen de contourner un défaut de cycle de vie.

## Validation et communication

- Distinguer les défauts confirmés dans les sources, les hypothèses, les tests exécutés, les tests ignorés et la validation sur iPhone.
- Une compilation réussie ou un test simulé ne démontre pas la stabilité sur iOS. Ne jamais annoncer un correctif « définitif », « stable » ou empêchant toute récidive sans preuve correspondante.
- Garder le même cycle de correction jusqu'à validation, avec un historique clair des résultats et des éventuels blocages. Ne pas envoyer une nouvelle IPA seulement pour tenter une autre hypothèse non vérifiée.
- Observation du 9 octobre 2026 : le mainteneur confirme la Build 422 installée sans doublons, mais des relancements RetroArch intermittents. Les vidéos montrent des jeux effectivement démarrés, et aussi une première demande à froid perdue. Des échecs à chaud sont également signalés : ne pas les attribuer automatiquement au défaut de scène froide. Voir `docs/retroarch-relaunch-2026-10-09.md` ; le patch proposé concerne le récepteur RetroArch et n'est pas appliqué au TestFlight installé.
- Comparaison supplémentaire 411–412–419 : les fichiers de liaison RetroArch, dépendances et générateurs de schémas iOS examinés ont les mêmes blobs Git. Le scanner est également identique à la livraison 422. La source publique RetroArch ajoute les scènes dans `630b36bd774c873b73bfaa59183822837dbc9aac` en omettant les URL initiales ; la classe demeure identique au SHA public `a7363feb909391c3217b91c30e81547e8208d6d5`. Cela établit un défaut public, pas l'identité du TestFlight 780 installé. Ne pas présenter une nouvelle URL, une fixture, ou une IPA NeoStation inchangée comme l'installation d'un correctif du récepteur tiers. Voir `docs/retroarch-411-412-comparison.md`.
- Candidat du récepteur réellement produit le 9 octobre 2026 : RetroArch privé 781, source de construction `560472630fb1064134d6feca27d6f7cb4e0efb64`, run `37918345079`, IPA SHA-256 `6d3b5dc86a39ef48398df83d56cddced0e01072b6f7a58d5c7bb3acbc877da11`, 190 470 031 octets, 126 cœurs précompilés, 129 signatures ad hoc vérifiées. Il s'utilise après re-signature Apple par SideStore ; il ne modifie pas le TestFlight installé et n'a pas été testé sur l'iPhone. Ne pas installer en supposant un routage déterministe entre deux applications enregistrant `retroarch://`, ni supprimer des données pour essayer le candidat. La préparation du conteneur et le choix d'installation doivent rester explicites. Voir `docs/retroarch-receiver-sidestore.md` pour les cœurs exclus/indisponibles et les durées observées. Les sources NeoStation restent identiques à la livraison 422, avec la bibliothèque de baseline 419.

## Traductions obligatoires — consigne du mainteneur du 23 septembre 2026

- Toute option, commande, description, notification, aide, erreur ou libellé d’accessibilité ajouté ou modifié dans NeoStation doit être traduit dans les douze langues prises en charge : `en`, `es`, `ru`, `zh`, `zh_Hant`, `pt`, `fr`, `de`, `it`, `id`, `ja`, `ko`.
- Utiliser les catalogues de traduction du projet. Ne pas ajouter de branche français/anglais ni afficher directement un message natif en anglais comme message utilisateur. Les noms de produits, identifiants, chemins et diagnostics techniques bruts restent inchangés, séparés de l’explication traduite.
- Pour chaque surface modifiée, vérifier automatiquement la présence de toutes les clés dans les douze langues, la conservation des paramètres de substitution et la sélection du chinois traditionnel. Un repli anglais ne remplace pas une traduction manquante dans une langue officiellement prise en charge.
- Inclure ces vérifications dans les tests obligatoires avant toute nouvelle IPA. Cette règle reste applicable aux interventions suivantes, sans nouveau rappel du mainteneur.
