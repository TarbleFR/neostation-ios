# NeoStation — candidat Build 414

Ce candidat prolonge `experimental` au commit `ab0f1b2531de080743a1d89baf80a5b6b9970c1e`. Il corrige l'échec du Build 413, sans relancer le Build 412 ni déplacer `main` ou `backup`.

## Causes établies

- Les tentatives f5ca362d, 966206d8, 3ceeacc9 et ab0f1b25 ont ajouté puis remplacé le broker NeoSwap par une allocation globale incompatible avec son API. Des déclarations étaient dupliquées, des fonctions imbriquées ou tronquées et des API mémoire inexistantes empêchaient la compilation C++/arm64.
- Les contrôles du candidat et NeoPlay étaient encore verrouillés sur les libellés du Build 412. Changer le numéro seul faisait échouer les contrôles ARMSX2, NeoPlay, Dolphin et les tests du frontend.
- Le nouveau helper mémoire ne libérait pas les réservations du noyau, lançait une boucle infinie et utilisait des capacités privées non documentées.

## Réparation et ajouts conservés

- Le broker canonique de bb347665 est remis dans les sources du candidat actuel. Ce fichier est identique à celui de 0f2d994b : il conserve les prêts donneur/relay, l'ABI v1, les allocations FAST, le cache de réutilisation, les quotas, la maintenance et les libérations différées. Aucune branche ni aucun ensemble de sources n'est ramené à une ancienne version.
- Les optimisations SPU, les contrôles de pression et de budget, les diagnostics RPCS3, les imports Vulkan et la préparation des pages invitées restent dans leurs sources canoniques. Les identités des cœurs sont conservées, notamment RPCS3 afb33454 / run 37620034517.
- Les correctifs NeoPlay/AirPlay et les restaurations des artefacts disparus du 7 octobre restent conservés. Ce candidat ne reconstruit pas l'application Windows NeoPlay.
- Le helper ajouté est conservé comme expérimentation explicite de réservation virtuelle, avec un plafond de 7 GiB, un contrôle de disponibilité actualisé, un suivi de chaque adresse, une vraie libération et des réactions à la pression mémoire. Il n'est jamais lancé au démarrage ni raccordé aux allocations du jeu ; RPCS3 conserve son broker. Sa réservation ne prouve pas l'utilisation de 7 GiB de RAM physique.
- Les nouvelles méthodes Dart sont conservées comme alias des diagnostics natifs existants. La validation des tailles et le traitement des réponses nulles sont rétablis. Les probes synthétiques restent désactivés dans les IPA distribuées.
- Les métadonnées du Build 414, les notes et les identités des fichiers modifiés sont alignées. Le contrôle exact du workflow ne permet que huit modifications de libellés et de notes ; les pins, contrôles précédents et preuves au SHA du candidat restent obligatoires.

## Validation requise

- Tests des réservations réelles et de leur destruction, avec disponibilité injectée pour le test, puis compilation du helper avec le SDK iPhone arm64.
- Tests du broker existant, ASan/UBSan, preuves donneur/relay/Vulkan et tests du frontend dans les douze langues.
- Vérifications KartPad UIKit et Flutter/SDL iOS 18 et iOS 27 au même SHA.
- Compilation complète de l'IPA et vérification de ses binaires, ressources, identités et version.

La validation sur iPhone et un éventuel gain de FPS restent à mesurer. Ni une réservation virtuelle, ni une preuve macOS/simulateur, ni une compilation réussie ne démontrent 7 GiB de RAM disponible en jeu.
