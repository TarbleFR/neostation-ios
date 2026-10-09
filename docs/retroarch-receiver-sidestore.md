# Candidat privé du récepteur RetroArch pour SideStore

## Périmètre

Ce candidat compile l'application RetroArch publique `a7363feb909391c3217b91c30e81547e8208d6d5` avec le patch `upstream/retroarch-initial-scene-url.patch`. Le patch transmet une seule fois les URL initiales de la scène au gestionnaire existant. Le schéma public `retroarch://`, la recherche des jeux et la sélection des cœurs restent identiques.

La bibliothèque NeoStation reste à la baseline 419. Les sources produit NeoStation sont celles déjà livrées et validées avec la Build 422, `00285ba5cfec694d59e1ca2bcf9de31418fd4e1a`. Cette opération ne génère pas une nouvelle IPA NeoStation, ne répare aucune base et n'accède à aucune donnée installée.

Le nouveau candidat RetroArch est identifié par la version `1.22.2`, le numéro privé `781` et l'identifiant de la distribution autonome upstream `com.libretro.RetroArchiOS11`. Il n'est pas une mise à jour du TestFlight 780, dont le SHA exact et les identités binaires des cœurs ne sont pas connus.

## Réutilisation et vérification

Le workflow `retroarch-receiver-ipa.yml` vérifie le succès du run `37857669052` au SHA `3c70b5f4adb80232d3c50d0b648520c7db5afe2c` ainsi que l'identité des entrées du contrôle du récepteur. Il réutilise ce résultat sans exécuter à nouveau les tests inchangés. Il vérifie également le succès de la livraison NeoStation 422 et l'identité des sources produit.

Les cœurs sont téléchargés précompilés depuis le buildbot officiel iOS ARM64. Le manifeste conserve URL, date, SHA-256 du ZIP et du binaire, taille et liste exacte. Les 13 cœurs explicitement référencés par les playlists fournies sont obligatoires ; les autres suivent la liste iOS App Store du script upstream. Une absence optionnelle est consignée. Aucun cœur d'émulation n'est compilé. Leur identité avec les cœurs du TestFlight installé ne peut pas être affirmée.

Le cache contient seulement ces dépendances publiques, vérifiées par leur manifeste. Le packaging personnalisé conserve leurs instructions et métadonnées ABI ; il évite la réécriture des load commands effectuée par le script upstream. MoltenVK vient du commit RetroArch épinglé. Les métadonnées de détection des cœurs proviennent de `libretro/libretro-core-info`, `5a74858ab2f7a50cebb5a6330895bc38899531c0`.

Xcode archive l'application en Release pour iPhoneOS ARM64, iOS 18 minimum. Les sources restent en optimisation Release et Thin LTO. Les signatures des frameworks, extensions et application sont scellées puis vérifiées individuellement et avec `codesign --verify --deep --strict`. Les sections de code, données et ABI sont comparées avant et après signature et contre les bytes effectivement exportés dans l'IPA. L'artefact et les diagnostics sont chiffrés pour le destinataire existant, sans publication supplémentaire du binaire.

## Installation à organiser après production

La signature ad hoc de préparation doit être remplacée par la signature Apple et le provisioning de SideStore. Aucun certificat Apple de distribution n'est revendiqué. L'installation effective, la disponibilité des App IDs et les droits des extensions restent à contrôler sur l'iPhone.

Ne pas supprimer le TestFlight ni ses documents pour essayer le candidat. Les identifiants de bundle sont différents : la nouvelle application ne récupère pas automatiquement son conteneur. Il faut sauvegarder les ROM, playlists, configurations et sauvegardes puis choisir explicitement comment préparer le conteneur du candidat. Aucune migration ni remise à zéro n'est automatique.

Ne pas considérer que deux applications enregistrant `retroarch://` coexistent avec un routage déterministe. Le protocole étant conservé pour la compatibilité avec NeoStation 422, le choix d'installation doit régler cette concurrence avant le test de liaison. Ce document ne constitue pas une autorisation de supprimer l'application existante ou ses données.

## Limites de validation

Les tests déjà réussis ont prouvé la réception des trois URL prises en charge, à froid et à chaud, sur UIKit simulé et avec un moteur d'enregistrement. Une compilation du vrai frontend augmente le niveau de validation mais ne prouve pas le démarrage d'un jeu sur l'iPhone. Les intermittences à chaud restent à diagnostiquer avec les journaux du récepteur réel ; elles ne sont pas automatiquement expliquées par le défaut de la scène froide.

Le workflow consigne les durées réellement observées de téléchargement/réutilisation des cœurs, d'archive native et de signature. Il ne substitue pas ces durées à la comparaison NeoStation 422, déjà mesurée sur deux runners comparables : 11 min 25 s sans cache appareil, 7 min 13 s avec cache. Aucun nouveau gain n'est présumé.

Premier run `37916992483`, commit `ad9f8f736a700df727269aba4ae2a63722897ef6` : compilation et archive réussies en 275,227 s, après 50,322 s de récupération des cœurs. Le contrôle final a refusé `hatarib`, fourni dans le répertoire iOS mais marqué macOS dans son Mach-O. Aucune IPA installable n'a été produite par ce run. Le contrôle est conservé : les cœurs incompatibles optionnels sont désormais identifiés et écartés avant l'archive ; un cœur obligatoire incompatible bloque la livraison. Leur liste complète accompagne le candidat. Les 13 cœurs liés explicitement dans les playlists ont été examinés séparément et sont tous ARM64 iOS avec un minimum d'iOS inférieur à 18.
