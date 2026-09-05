# NeoSync — régression Build 204 et réparation Build 205

Date : 5 septembre 2026. Destinataire : maintenance de NeoStation et utilisateur de l’IPA iOS.

## Pourquoi cela a cassé

La règle « uniquement sauvegardes internes et savestates » avait été traduite en un filtre global de noms/extensions, sans réconcilier ce filtre avec les dossiers et les unités natives des émulateurs. Les tests de Build 204 validaient des exemples du filtre et la sécurité des suppressions ; ils ne couvraient pas toute la chaîne découverte → transfert → état → restauration des autres émulateurs.

| Cause constatée dans le code 204 | Conséquence | Correction |
| --- | --- | --- |
| `loadOnlineFiles` plaçait un audit incomplet dans `_error`; l’icône consultait cette erreur avant l’état du jeu. | Un fichier d’origine inconnue rendait tous les jeux rouges. | Diagnostic d’audit distinct ; état et erreur propres au jeu. |
| Le scan conservait les fichiers non classés, mais `allowsUpload` les refusait. | Une sauvegarde visible pouvait être impossible à synchroniser. | Origine validée dans les dossiers configurés, partagée par découverte et envoi. |
| La découverte produisait des chemins `saves/...`, l’envoi des chemins `v2/saves/...`. | Le même fichier semblait absent de l’autre côté. | Même construction et comparaison d’identité canonique ; récupération des anciens noms séparés du chemin serveur. |
| MeloNX était interprété comme un arbre Yuzu à Title ID. | Les conteneurs natifs à SaveDataId étaient ignorés, tandis que des chemins trop larges incluaient du contenu étranger. | Lecture des métadonnées natives, sélection du contenu enregistré et conservation du profil/conteneur. |
| Chaque constituant était traité comme une sauvegarde indépendante. | PARAM.SFO, icônes et données apparaissaient sur plusieurs lignes ; restaurations partielles possibles. | Une unité native par entrée/action ; arborescence conservée, staging complet et rollback sur échec. |
| Certains échecs étaient explicitement convertis en `upToDate`; ailleurs taille/date suffisaient. | Indicateur vert sans preuve de synchronisation. | Comparaison de tous les membres et de leurs empreintes, confirmation des transferts, contrôle du compte. |

## Dossiers et limites

| Famille | Source autorisée | Unité |
| --- | --- | --- |
| RetroArch | Dossiers saves/states réellement configurés, avec sous-dossier du cœur si présent | SRAM/sauvegarde, compagnon RTC vérifié, ou état individuel |
| PPSSPP via RetroArch | Racine de sauvegarde puis `[PPSSPP/]PSP/SAVEDATA/<identifiant>/` | Répertoire savedata complet ; GAME/DLC, TEXTURES, SYSTEM et caches exclus |
| ARMSX2 | Bookmark existant puis `memcards`, `savestates` ou `sstates` | Carte individuelle, carte en répertoire, ou état individuel |
| RPCS3 | Bookmark Data puis `dev_hdd0/home/<profil>/savedata/<répertoire>/` | Répertoire complet, y compris PARAM.SFO et images nécessaires |
| MeloNX | Racine liée puis `bis/user/save/<SaveDataId>/` ou sous-racine équivalente | Métadonnées ExtraData permettant d’identifier jeu/profil ; contenu enregistré `0`, ou `1` uniquement si NoJournal est confirmé |
| Flycast | Saves configurés et fichiers VMU précis dans `system/dc` | VMU ; aucun BIOS ni NVRAM système |
| DolphiniOS | Adaptateur natif déjà validé en Build 204 | Conteneur de sauvegarde existant ; titre sur les états, `GC Memory cards` sur les sauvegardes internes GC |

Les objets historiques d’origine inconnue sont retirés de la liste active et conservés pour investigation. Seuls les objets prouvés étrangers sont supprimés du cloud. Les fichiers locaux de jeux, DLC et BIOS ne sont pas supprimés. Aucun accès direct au compte NeoSync de l’utilisateur n’était disponible pendant cette réparation : l’audit s’exécute sur son appareil authentifié.

Une restauration MeloNX ne fabrique pas un index ou un profil natif. Le conteneur correspondant doit exister dans l’émulateur. Les envois restent effectués par constituant avec confirmation de contenu ; aucun manifeste de révision serveur ne garantit un instantané distant atomique en cas d’interruption entre deux envois. La transaction de restauration protège les échecs pendant son exécution ; elle ne prétend pas fournir un journal de reprise après extinction forcée du téléphone.

## Sources vérifiées et provenance

- Dépôt NeoStation, parent de réparation `cbfc7859109bc4a75a17d1b52498a72e320edc17` : fichiers provider/status/core/path resolver, service et icône. Preuve directe des chaînes de causalité ci-dessus.
- [Libretro — Directory configuration](https://docs.libretro.com/guides/change-directories/), documentation officielle, datée du 28 février 2024, consultée le 5 septembre 2026 : les dossiers configurés font autorité et peuvent varier par installation.
- [Libretro — PPSSPP](https://docs.libretro.com/library/ppsspp/#directories), documentation officielle, consultée le 5 septembre 2026 : distinction SAVEDATA/GAME/SYSTEM sous les dossiers du cœur.
- [Libretro — Flycast](https://docs.libretro.com/library/flycast/#directories), documentation officielle, consultée le 5 septembre 2026 : VMU dans saves et system/dc.
- [Libretro — LRPS2](https://docs.libretro.com/library/lrps2/), documentation officielle, consultée le 5 septembre 2026 : absence de prise en charge iOS/ARM ; aucun scan global system/pcsx2 ajouté sur iOS.
- [RPCS3 — Quickstart](https://rpcs3.net/quickstart), documentation officielle, consultée le 5 septembre 2026 : emplacement natif des savedata distinct des jeux installés.
- [LibHac — DirectorySaveDataFileSystem](https://git.ryujinx.app/projects/LibHac/src/commit/aa8a40f410f7b9fc7b6eee5107bf66821d0ecef6/src/LibHac/FsSystem/DirectorySaveDataFileSystem.cs), code source figé, vérifié dans une copie locale : répertoires `0`, `1`, `_`, ExtraData0/1 et comportement avec/sans journal.
- [LibHac — SaveDataTypes](https://git.ryujinx.app/projects/LibHac/src/commit/aa8a40f410f7b9fc7b6eee5107bf66821d0ecef6/src/LibHac/Fs/Common/SaveDataTypes.cs), code source figé, vérifié dans une copie locale : structure ExtraData, types Account/Device et format NoJournal.
- [MeloVertex — code conservé de VirtualFileSystem](https://github.com/VertexSelection/MeloVertex/blob/fcd0dc995d3c7e104bcd8a2a0f779d91227be324/src/Ryujinx.HLE/FileSystem/VirtualFileSystem.cs), fork conservant le code MeloNX : construction du chemin par SaveDataId. Le dépôt MeloNX d’origine n’était plus public ; aucune validation sur les fichiers réels du téléphone n’est revendiquée.

La recherche s’arrête après réconciliation des formats nécessaires et vérification du code primaire. Les cas non prouvés sont exclus de la synchronisation active, sans suppression spéculative.

## Vérification

Tests ciblés : diagnostic global sans faux rouge, erreurs HTTP, pagination tronquée, confirmation d’upload, identités/checksums, fichiers natifs MeloNX réels simulés à partir du format ExtraData, regroupement de 15 constituants, séparation profils/slots, exclusion DLC/BIOS, restauration interrompue et rollback. La compilation Flutter/Xcode et l’audit de l’IPA sont exécutés par le workflow permanent sur le commit livré. Les résultats précis de compilation accompagnent l’artefact CI ; les essais sur iPhone restent distincts des tests automatisés.
