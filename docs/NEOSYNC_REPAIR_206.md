# NeoSync — réparation du protocole, Build 206

Date : 6 septembre 2026. Référence avant correction : Build 205, commit `16e7be7eb6e6959e43eb527733eceac052b39ad4`.

## Ce que le retour sur appareil a révélé

Le fonctionnement de DolphiniOS et de son enregistrement est confirmé par l’utilisateur. NeoSync reste en échec sur Wii, GameCube et N64 ; la capture montre 26,5 Mo utilisés, mais aucune sauvegarde dans la liste. Le quota seul ne permet pas de conclure à une perte de données.

## Pourquoi les correctifs précédents ne suffisaient pas

Le [changement officiel du 4 septembre](https://github.com/misobadev/neostation-frontend/commit/11d3f7fdd127910e45a1b2759b96a02581ee6ae6) sépare maintenant le chemin relatif `file_path` et le type `save/state/shared/custom` des métadonnées de système et d’émulateur. Notre fork utilisait encore une ancienne clé composée dans `file_name` et ignorait les nouveaux champs des réponses.

| Écart vérifié dans le code 205 | Effet | Réparation 206 |
| --- | --- | --- |
| Upload sans `file_path` et `type` ; vérification préalable sur l’ancienne clé | Requêtes incompatibles avec le client officiel actuel | Même chemin relatif pour vérification, upload et confirmation, avec type et contexte explicites |
| Modèle ignorant les métadonnées de routage et exigeant un nom distinct | Fichiers non reconnus puis masqués par le filtre « sauvegardes uniquement » | Décodage des métadonnées et reconstruction de l’identité locale, tout en conservant l’identifiant serveur |
| Conteneurs Dolphin portant le même nom pour plusieurs jeux | Un nom seul ne permet pas une association sûre | Identifiant natif conservé dans le chemin du conteneur ; récupération historique uniquement avec preuve exacte |
| Appel automatique à un ancien déploiement | Avertissement sans rapport avec la disponibilité v2, masquant le diagnostic utile | Inventaire courant indépendant ; aucune migration automatique supposée |
| Carte globale toujours intitulée « synchronisées » | Une connexion réussie semblait prouver tous les transferts | Indication d’activation/synchronisation/erreur ; statut propre à chaque jeu |

Les tests 205 simulaient essentiellement des réponses contenant déjà la clé canonique attendue. Ils confirmaient les filtres et les mécanismes de protection sans exercer le nouveau format effectivement publié. Cette lacune explique le succès des tests malgré l’échec constaté sur appareil. Les nouveaux cas imposent les champs du contrat publié et leurs aller-retour, ainsi que le refus des réponses ambiguës.

## Conservation des sauvegardes

La règle reste : sauvegardes internes, cartes mémoire et savestates uniquement. Les composants d’un même savedata sont regroupés ; jeux, DLC, BIOS et vidéos ne deviennent pas des sauvegardes. Un type serveur déclaré « save » ne suffit pas à prouver que son contenu est autorisé. Les objets d’origine non prouvée ne sont pas supprimés au hasard et leur présence est signalée au lieu d’afficher une absence certaine de sauvegardes.

La [migration v2 officielle](https://github.com/misobadev/neostation-frontend/pull/336) distingue les anciens fichiers v1 et prévoit leur récupération manuelle. Elle ne justifie pas de bloquer les sauvegardes v2 sur un ancien domaine. Aucun accès au compte authentifié de l’utilisateur n’est disponible ici ; aucune suppression ou restauration effective dans son compte n’est revendiquée.

## Vérification et limites

Les sources primaires sont le client officiel figé et le code du fork. Le serveur privé et les réponses authentifiées du téléphone ne sont pas accessibles : les cas de test reproduisent le contrat publié, ce ne sont pas des captures du compte de l’utilisateur. Les tests de protocole, classification, récupération et restauration précèdent les tests Flutter, le simulateur natif et la compilation Xcode. Le workflow attache le commit exact et le rapport d’audit à l’IPA.

Le cœur Dolphin, l’enregistrement, le menu en jeu et ses réglages restent ceux du Build 205 validé par l’utilisateur. Une compilation réussie reste distincte d’une vérification de NeoSync avec les données de son téléphone.
