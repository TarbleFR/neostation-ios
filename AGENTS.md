# Consignes permanentes — stabilité NeoStation iOS

Ces règles expriment les exigences du mainteneur du 18 septembre 2026 et s'appliquent à toute intervention sur ce dépôt.

## Une seule référence de travail

- La baseline officielle Build 273, commit `8558dc782b98b114f944514e27722fe1a5faff48`, reste immuable. Ne pas modifier `main`, `backup` ou déplacer une référence de baseline pour résoudre un problème sur `experimental`.
- Travailler sur une seule version candidate clairement identifiée pendant le cycle de correction. Chaque modification crée naturellement un nouveau SHA : consigner ce SHA exact, ne pas mélanger des binaires ou des résultats de tests provenant de révisions différentes.
- Ne jamais réutiliser le nom d'un artefact pour faire passer une autre révision pour celle déjà testée. Associer version, SHA, entrées natives et résultats de validation.

## Corriger avant de compiler

- Revenir à une ancienne version n'est pas un correctif. Identifier le chemin fautif, corriger la cause établie et tester le comportement avant de lancer une nouvelle compilation IPA.
- Ne plus superposer les correctifs. Les sources canoniques suivies par Git doivent contenir directement les corrections. La CI ne doit pas rejouer une succession de patches historiques VPN, RPCS3 ou Dolphin pour fabriquer des sources différentes de celles examinées.
- La migration des anciennes couches doit être une opération ponctuelle de mise à plat des sources, revue et commitée, jamais une nouvelle étape cachée exécutée à chaque compilation.
- Ne pas reconstruire ni modifier des cœurs, helpers JIT, scripts de débogage ou réglages d'émulation sans lien établi avec le défaut traité. Conserver et vérifier leurs identités lorsqu'ils doivent rester inchangés.

## Empêcher le retour des régressions

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
