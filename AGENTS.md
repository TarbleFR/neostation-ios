# Consignes permanentes — stabilité NeoStation iOS

Ces règles expriment les exigences du mainteneur du 18 septembre 2026 et s'appliquent à toute intervention sur ce dépôt.

## Une seule référence de travail

- Le mainteneur adopte la Build 419 comme nouvelle baseline le 8 octobre 2026 : référence source `9e0aca6a34034102b2e6aa083b1588b274b83e5f`, notamment pour le comportement de bibliothèque. Ne pas réutiliser le numéro 419 pour une nouvelle livraison. Aucun SHA d'IPA Build 419 n'est attesté ici. La Build 350 reste uniquement le donneur natif historiquement vérifié (`5e6dc00b35b7bb7847c24198d9f4b08ade8ed9a0`, run `36323843067`, IPA SHA-256 `e1017b96842ec970be3ed0cd981083ee945d069cf76e689a4ca3c81339299b46`). Ne pas modifier `main`, `backup` ou les références Git de baseline sans demande explicite.
- Travailler sur une seule version candidate clairement identifiée pendant le cycle de correction. Chaque modification crée naturellement un nouveau SHA : consigner ce SHA exact, ne pas mélanger des binaires ou des résultats de tests provenant de révisions différentes.
- Ne jamais réutiliser le nom d'un artefact pour faire passer une autre révision pour celle déjà testée. Associer version, SHA, entrées natives et résultats de validation.

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

## Traductions obligatoires — consigne du mainteneur du 23 septembre 2026

- Toute option, commande, description, notification, aide, erreur ou libellé d’accessibilité ajouté ou modifié dans NeoStation doit être traduit dans les douze langues prises en charge : `en`, `es`, `ru`, `zh`, `zh_Hant`, `pt`, `fr`, `de`, `it`, `id`, `ja`, `ko`.
- Utiliser les catalogues de traduction du projet. Ne pas ajouter de branche français/anglais ni afficher directement un message natif en anglais comme message utilisateur. Les noms de produits, identifiants, chemins et diagnostics techniques bruts restent inchangés, séparés de l’explication traduite.
- Pour chaque surface modifiée, vérifier automatiquement la présence de toutes les clés dans les douze langues, la conservation des paramètres de substitution et la sélection du chinois traditionnel. Un repli anglais ne remplace pas une traduction manquante dans une langue officiellement prise en charge.
- Inclure ces vérifications dans les tests obligatoires avant toute nouvelle IPA. Cette règle reste applicable aux interventions suivantes, sans nouveau rappel du mainteneur.
