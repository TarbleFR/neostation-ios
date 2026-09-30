# RPCS3 / XITRIX v0.10.1 — audit du candidat NeoStation

Audit arrêté au 30 septembre 2026, en UTC. Trois correctifs de justesse de
XITRIX v0.10.1 sont intégrés sélectivement au delta canonique local : continuité
SPU, nettoyage des textures désactivées et rendu conditionnel MoltenVK. Ils
corrigent des chemins identifiés et couverts par des régressions natives. Ils
ne constituent pas une mesure d'accélération de God of War III.

Notre moteur est déjà natif ARM64, avec recompilation PPU/SPU vers AArch64 et
plusieurs optimisations issues de XITRIX/ARMSX3. La capture à 4,2 FPS ne suffit
pas à déterminer lequel de la progression PPU/SPU, des attentes RSX/GPU, de la
compilation ou de la pression mémoire domine. Une donation réelle de RAM est
une enquête distincte encore en cours ; ces backports ne l'implémentent pas
et cet audit n'en apporte aucune validation. Aucun test sur iPhone,
benchmark du jeu ou gain de FPS n'est
revendiqué ici.

## Sources primaires et identité examinée

Le propriétaire résolu est **XITRIX**, et les sources iOS sont dans
**XITRIX/rpcs3**, branche **ios-port**. Le dépôt de publications est séparé :
**XITRIX/RPCS3-iOS-Releases**. La branche `master` de RPCS3, restée ancienne,
ne représente pas le port iOS récent.

| Référence | Date UTC | Identité et source primaire |
| --- | --- | --- |
| Publication iOS v0.10.1 | 2026-09-29 19:33:52 | [Tag v0.10.1](https://github.com/XITRIX/RPCS3-iOS-Releases/releases/tag/v0.10.1) |
| Publication iOS v0.10 | 2026-09-27 22:02:00 | [Tag v0.10](https://github.com/XITRIX/RPCS3-iOS-Releases/releases/tag/v0.10) |
| Dernière tête iOS examinée | 2026-09-29 18:43:27 | [6747b75ac96d43674d58e822c527ec6b07519c5f](https://github.com/XITRIX/rpcs3/commit/6747b75ac96d43674d58e822c527ec6b07519c5f) |
| Référence du précédent import sélectif v0.10 / Build 353 | 2026-09-27, publication associée | [559987e966db0f8ac983502a160b419968e2474d](https://github.com/XITRIX/rpcs3/commit/559987e966db0f8ac983502a160b419968e2474d) ; [audit Build 353](rpcs3-xitrix-v010-build353.md) |
| Base immuable du delta NeoStation | 2026-09-07 23:00:03 | [22f1152783cef1f7e04af7b1c895173e28fd5b03](https://github.com/XITRIX/rpcs3/commit/22f1152783cef1f7e04af7b1c895173e28fd5b03) |
| Autre source ARM64 examinée, ARMSX2/ARMSX3 `master` | 2026-09-27 13:03:05 | [a6b7cb0c96409d1f3865ca902ef90afe128c2a1d](https://github.com/ARMSX2/ARMSX3/commit/a6b7cb0c96409d1f3865ca902ef90afe128c2a1d) |
| Dernière publication ARMSX3 listée | 2026-09-27 09:40:28 | [Tag 1.0.5](https://github.com/ARMSX2/ARMSX3/releases/tag/1.0.5) |

Les tags, dates de publication et têtes ont été lus dans les réponses GitHub
du dépôt officiel, puis les fichiers comparés avec les sources locales
matérialisées. Au dernier contrôle, la liste des publications affichait
toujours v0.10.1 en premier. Les index de recherche publics plus anciens, qui
mentionnent encore v0.9, ne servent pas à déterminer la dernière version.
Le point d'accès GitHub `releases/latest` renvoie 404 pour ce dépôt ; la
[liste des publications](https://api.github.com/repos/XITRIX/RPCS3-iOS-Releases/releases?per_page=5)
a été utilisée.

La branche iOS a été rebasée le 29 septembre. Le comparatif GitHub avec la
référence v0.10 présente 169 commits d'avance et 138 de retard : ce n'est pas
169 nouvelles optimisations indépendantes. L'audit porte sur les différences
des fichiers et les changements retenus, sans remplacement intégral du Core.
Le dépôt de releases n'établit pas à lui seul une attestation liant son IPA
à un SHA source précis. Le digest annoncé de `RPCS3.ipa` v0.10.1 est
`e017a90947c3058f2c55b33d8a177be6591157afcdcdd97c7725b15e9ec1b625` ;
cet IPA n'a pas été installé ni mesuré dans cet audit.

La licence principale du moteur et des fixtures amont est GPL-2.0-only :
[README](https://github.com/XITRIX/rpcs3/blob/6747b75ac96d43674d58e822c527ec6b07519c5f/README.md),
[LICENSE](https://github.com/XITRIX/rpcs3/blob/6747b75ac96d43674d58e822c527ec6b07519c5f/LICENSE).
Les mentions propres aux fichiers et les licences des dépendances restent à
conserver. Le [README ARMSX3](https://github.com/ARMSX2/ARMSX3/blob/a6b7cb0c96409d1f3865ca902ef90afe128c2a1d/README.md)
donne également GPL-2.0-only. Les parties Android, interfaces et pilotes ne
sont pas directement transposables à iOS.

## Trois backports retenus

| Correctif amont | Défaut et changement appliqué | Portée |
| --- | --- | --- |
| [8bd938e9de9ff6455f312cdf8bd64bd37a064c4e](https://github.com/XITRIX/rpcs3/commit/8bd938e9de9ff6455f312cdf8bd64bd37a064c4e), 2026-09-29 18:10:03 | `SPUCommonRecompiler.cpp` omettait l'arête et le bloc de continuation d'un `BI/BID` désactivant les interruptions lorsque la cible connue est l'instruction suivante. Le bloc est désormais enregistré avant de terminer l'analyse de cette branche. | Cohérence du graphe SPU et de ses prédécesseurs, utilisée ensuite par les recompilateurs LLVM/ASMJIT. |
| [1d13d1e6bbabfbb7a873f2c608c52525ff470e25](https://github.com/XITRIX/rpcs3/commit/1d13d1e6bbabfbb7a873f2c608c52525ff470e25), 2026-09-29 18:10:03 | `VKGSRender::on_vram_exhausted` ignore désormais les slots de textures fragment/vertex désactivés avant de traduire leur adresse. Une adresse périmée d'un slot désactivé ne doit pas faire échouer la collecte des exclusions. | Robustesse du nettoyage sous pression mémoire ; une adresse invalide d'un slot actif reste une erreur. |
| [6747b75ac96d43674d58e822c527ec6b07519c5f](https://github.com/XITRIX/rpcs3/commit/6747b75ac96d43674d58e822c527ec6b07519c5f), 2026-09-29 18:43:27 | `VKHelpers.cpp` calcule l'émulation du rendu conditionnel après avoir identifié le pilote et l'exclut pour MoltenVK. | MoltenVK résout le prédicat côté CPU ; l'émulation shader lisait un tampon de repli nul et pouvait rejeter des draws valides. |

Le correctif MoltenVK ne modifie pas les réglages par défaut du titre et ne
force pas `Relaxed ZCull`. Le correctif de nettoyage n'augmente ni la RAM
physique ni le débit CPU. Le correctif SPU rend un chemin exécutable cohérent,
sans prédire sa fréquence ni son coût dans le jeu complet.

Les objets SPU persistants produits avec le graphe incomplet doivent être
recompilés. La version du cache SPU passe de **4 à 5** dans la clé du cache.
C'est une invalidation ciblée des objets compilés, sans suppression des
sauvegardes ou de la bibliothèque. L'ABI principale iOS reste **30**.

## Contrat canonique et politiques conservées

La source reste la base `22f1152783cef1f7e04af7b1c895173e28fd5b03` plus
**un seul** delta : `build-utils/rpcs3/embedded-core.patch`. Son SHA-256 est
`36ff8cf3f7073e6d573a9bab91f7c1f8a11df72b2fce52ce532c041080d36ac3`.
`build-utils/rpcs3/canonical-source.json` décrit 121 postimages vérifiées et
les trois commits sélectionnés. Une nouvelle matérialisation du delta a été
vérifiée ; aucune pile de patches historiques n'a été ajoutée.

Huit postimages changent ou sont ajoutées par rapport au delta précédent :
les trois fichiers moteurs ci-dessus, `NeoSwapClient.h`,
`NeoSwapClientStats.h`, `RPCS3IOS.cpp`, `RPCS3IOS.h` et `RPCS3IOS.exports`.
Les autres postimages conservent leur identité.

Les politiques critiques conservées comprennent le cycle de vie Build 350,
le JIT iOS et ses arènes/réservations, les budgets de compilation PPU,
les réservations VM, les restaurations de stacks 4 Kio et les savestates.
La [politique mémoire GoW III Build 352](rpcs3-gow3-memory-build352.md)
reste limitée aux six identifiants reconnus ; le contournement MLAA reste
soumis au titre, aux hashes PPU/SPU attendus et à l'option correspondante.
Les décodeurs et les réglages globaux ne sont pas remplacés par ceux de
la dernière release XITRIX.

## Régressions exécutées et limites de preuve

`test/rpcs3_xitrix_v0101_native_test.py` compile et exécute des extraits du
code de production matérialisé, avec les fixtures natives. Il est appelé par
`build-utils/build_rpcs3_embedded_core.sh` et la gate
`.github/workflows/rpcs3-core.yml`.

| Vérification | Résultat local | Ce que le test établit |
| --- | --- | --- |
| Analyseur SPU réel et gardes des deux recompilateurs | 54 cas réussis | Continuations, boucles et prédécesseurs conservés ; écriture de registre après `BID`, `RdMachStat`, cibles inconnues et branches avec interruptions actives ; trois adresses et modes safe/mega/giga. |
| Ancien Core soumis à la régression SPU | Échec attendu observé | La régression distingue effectivement le défaut antérieur du correctif. |
| Scan d'exclusion Vulkan réel avec textures simulées | 131 111 vérifications réussies | Combinaisons de slots fragment/vertex, adresse périmée désactivée ignorée et adresse invalide active encore rejetée. |
| Initialisation du pilote et politique conditionnelle réelles | 24 cas réussis | MoltenVK/autres pilotes, disponibilité matérielle, option et réinitialisation ne conservent pas un état erroné. |
| Getter facultatif NeoSwap compilé dans une unité distincte | Réussi | Taille/version/null, disposition du contrat, compteurs partagés entre unités et absence de constructeur statique ou dépendance au broker dans ce getter. |
| Cache et identité du contrat | Réussi | Namespace SPU v5, ABI principale 30 et symboles exports attendus. |

Les fixtures SPU et de pression Vulkan proviennent de l'amont GPL ; les
tests supplémentaires de rendu conditionnel et de getter exécutent les
expressions/corps extraits du Core examiné. Les simulations remplacent les
services extérieurs nécessaires ; elles ne reproduisent pas un GPU iPhone.

Le cas SPU vise le motif rapporté dans la **démo de God of War III**. Les
instructions synthétiques couvrent le `BID` et la continuation, y compris
une écriture de registre visible. Le runner accepte aussi `--guest` pour
une reconstruction légitime complète du local store de 256 Kio : entrée
`0xbf18`, `BID` `0xc17c`, continuation `0xc180`, merge `0xc050`, sortie
`0xc1b8`. **Cette image guest n'était pas disponible et ce mode n'a pas été
exécuté.** Le résultat obtenu est une démonstration de non-régression du
graphe synthétique, pas l'exécution de la démo ou un benchmark GoW III.

Les vérifications existantes de préprocesseur, chargement passif, démarrage
atomique, GoW3 Build 264/351/352, import v0.10 Build 353 et contrats ARMSX3 ont
aussi réussi sur la source vérifiée. La syntaxe des scripts et le diff ont
été contrôlés. Les régressions natives ont été exécutées sous Linux avec
Clang 18 ; cet audit n'a pas produit un nouveau binaire complet iOS, une
nouvelle IPA ou un test physique. La Build 367 déjà compilée ne contient pas
par anticipation ces nouvelles modifications locales.

## ARM64 : ce qui existe réellement

L'hôte iOS exécute du code ARM64 et LLVM recompile déjà les instructions
invitées PPU/SPU vers AArch64. Le code PS3 et ses synchronisations restent
émulés ; le caractère natif du code généré ne supprime pas ce travail.

Dans `build-utils/build_rpcs3_embedded_core.sh`, LLVM est construit avec
`LLVM_TARGETS_TO_BUILD=AArch64`. Le ThinLTO sélectif est activé pour le
moteur, sans appliquer cette politique à LLVM, FFmpeg ou MoltenVK.
`USE_NATIVE_INSTRUCTIONS=OFF` concerne la compilation portable du binaire
hôte ; cela ne désactive pas la sélection de CPU et de features du JIT.

La lecture de `Utilities/JITLLVM.cpp` corrige une interprétation trop large
du repli `-mcpu` : un CPU LLVM explicitement configuré est utilisé en
priorité ; sinon LLVM consulte **`getHostCPUName()`**. Seulement si le nom
retourné vaut `generic`, la détection de repli ARM64 hors Android choisit
`cortex-a78`. On ne peut donc pas conclure que chaque iPhone utilise toujours
ce modèle. Le CPU effectivement résolu doit être relevé dans les logs de
la session concernée avant d'envisager une autre cible.

Le JIT MCJIT utilise le niveau d'optimisation agressif et `setMCPU`. Les
features `sha3`, `dotprod`, `i8mm`, `sve` et `sve2` sont ajoutées ou retirées
selon les détections matérielles. L'annonce `i8mm` est déjà présente, ce qui
évite de générer un intrinsèque `ummla` sans la feature LLVM correspondante.
Le triple ARM64 Apple **`aarch64-unknown-linux-android`** est intentionnel
pour réserver `x18`. Le renommer automatiquement en triple iOS peut casser
le contrat de registres du JIT ; il ne s'agit pas d'une piste gratuite.

Les apports ARM64 déjà présents incluent les lowerings NEON SPU, les
comparaisons et tables, les chemins rapides d'octets, le hash et la copie
des réservations, les barrières mémoire et les corrections PPU OE/CR0/NaN.
La suppression des helpers LLVM SPU inaccessibles et la désactivation du
pass LLVM InterleavedLoadCombine ont déjà été importées. Leur présence ne
doit pas être comptée une seconde fois comme une nouveauté v0.10.1.
Voir les fichiers `SPULLVMRecompiler.cpp`, `SPUARM64Lowering.h`,
`SPUARM64CompareLowering.h`, `SPUThread.cpp`, `PPUTranslator.cpp` et l'audit
Build 353. Un ajout amont du pass InstCombine a ensuite été retiré : un
changement annulé n'est pas une optimisation à réintroduire sans preuve.

## Pistes identifiées, non importées

| Source primaire | Intérêt potentiel | Validation nécessaire avant intégration |
| --- | --- | --- |
| [979250177b1f4e08e483e873cfe86c91548a0e14](https://github.com/XITRIX/rpcs3/commit/979250177b1f4e08e483e873cfe86c91548a0e14) et [7af363c1258515550c59519e69a592dcc997d6cf](https://github.com/XITRIX/rpcs3/commit/7af363c1258515550c59519e69a592dcc997d6cf), historique iOS du 29/09 | Horloge guest et scopes de pause pendant compilation synchrone PPU/SPU/shaders ; le watchdog hôte continue. Peut corriger expirations et incohérences de temps. | Revue de System/sys_time, decrementer, audio et savestates ; pauses imbriquées, workers asynchrones, exceptions et destruction avant asm/longjmp ; cohérence des clés de caches. N'ajoute pas de capacité CPU/GPU. |
| [5b0e829e64671899a59d0a6c3ac1f9fc7cb4efec](https://github.com/XITRIX/rpcs3/commit/5b0e829e64671899a59d0a6c3ac1f9fc7cb4efec), 29/09 | Retrait du compilateur shader Legacy et migration vers recompilation avec interpréteur, également annoncés en v0.10.1. | Migration des YAML globaux, par titre et presets, chargement de savestates, images et coût de l'interpréteur. Le changement de défaut n'est pas inclus dans les trois backports. |
| [615f529e65ebbd898cfe380d24fde0fecae4a126](https://github.com/XITRIX/rpcs3/commit/615f529e65ebbd898cfe380d24fde0fecae4a126), historique rebasé du 29/09 | Contournement des macros LSE2 absentes avec certains compilateurs LLVM sur Apple AArch64 dans `util/types.hpp`. | Vérifier les macros réellement définies par notre Apple Clang, les atomiques 128 bits produites et les appareils supportés. Le message amont précise qu'AppleClang définit déjà ces macros ; aucun manque ni gain n'est établi pour notre build. |
| [ARMSX3 a2b2fb049a8acf7e094623a742b00822898adf9e](https://github.com/ARMSX2/ARMSX3/commit/a2b2fb049a8acf7e094623a742b00822898adf9e), 20/09 | Désactivation du pliage `SHUFB` vers insert sur ARM64 après un défaut signalé dans Killzone 3. Notre Core et XITRIX iOS conservent cette famille de pliages. | Le signal concerne un autre jeu et une interaction de codegen non élucidée ; les contrôles arithmétiques de l'auteur n'observaient pas de divergence. Test différentiel dédié, appareils Apple, cache et stabilité requis. Pas de preuve que GoW3/iOS soit touché, ni d'accélération annoncée. |

Des correctifs RSX plus récents de query sans écriture et de choix des
surfaces en chevauchement existent aussi :
[b0be9677ac0aaf49bb2cfcf066cba77648486b16](https://github.com/XITRIX/rpcs3/commit/b0be9677ac0aaf49bb2cfcf066cba77648486b16),
[f2adfeb359cb8bfd9cd33ce522c753a85c6f4a5d](https://github.com/XITRIX/rpcs3/commit/f2adfeb359cb8bfd9cd33ce522c753a85c6f4a5d).
Ils restent des pistes de justesse avec tests graphiques à construire.
Le [correctif audio d60afae856e29cd7413040b149d8994c955a48ba](https://github.com/XITRIX/rpcs3/commit/d60afae856e29cd7413040b149d8994c955a48ba)
dépend de la chaîne audio shared-memory volontairement absente de notre
import ; il ne peut pas être appliqué isolément à une fonction inexistante.

## Lecture de la capture à 4,2 FPS

La capture fournie indique **4,2 FPS, CPU 72 %, RSX 40 %, mémoire 4,76 / 7,44 Gio**.
Ces valeurs décrivent un instant et des agrégats différents. Dans les sources
canoniques examinées, leur signification est la suivante :

| Valeur | Calcul dans le Core | Limite de l'interprétation |
| --- | --- | --- |
| FPS | Frames présentées divisées par le temps écoulé de l'échantillon (`RPCS3IOSPerformance.cpp`). | Ne distingue pas travail CPU, attentes, compilation et présentation. |
| CPU | Temps CPU du processus, normalisé par le nombre de processeurs logiques retourné par `get_thread_count()`, puis borné à 0–100 (`util/cpu_stats.cpp`). | 72 % ne décrit pas le thread critique PPU/SPU et ne prouve pas qu'il lui reste 28 % de capacité exploitable. |
| RSX | Charge approximative du thread RSX, à partir du temps écoulé moins son temps idle sur environ 30 frames (`RSXThread::get_load`). | 40 % n'est pas une mesure d'occupation du GPU Metal. Un thread peut attendre alors qu'un autre limite la progression. |
| Mémoire utilisée / totale | `TASK_VM_INFO.phys_footprint` du processus / `utils::get_total_memory()` de l'appareil. | 7,44 n'est ni le plafond jetsam garanti au processus ni la RAM encore disponible. 4,76 peut être préoccupant sans prouver la cause des 4,2 FPS. |

Une conclusion utile demande des mesures simultanées sur la même séquence :
PPU/SPU et thread critique, attentes range-lock/mailbox, JIT et shaders,
attentes RSX/présentation, pression mémoire et marge iOS, état thermique,
résolution et erreurs graphiques. Le profilage CPU/GPU et les compteurs de
pression doivent être corrélés ; le seul pourcentage RSX ne remplace pas
une capture de temps GPU.

## NeoSwap : couverture réelle, zéro et donation

Le hook RPCS3 actuel est dans `RSX/Common/aligned_malloc.hpp`. Sous iOS, il
essaie le client NeoSwap pour les **données CPU RSX alignées d'au moins
1 Mio**, puis utilise l'allocateur habituel si l'essai n'aboutit pas. Les
reallocations conservant leur capacité ne font pas de nouvel essai ; une
croissance passe par le wrapper et copie les données avant de libérer
l'ancien bloc. Ce hook ne transfère pas automatiquement toute la mémoire
du moteur vers NeoSwap.

Les appels effectifs passent essentiellement par `rsx::simple_array`,
notamment des temporaires de conversion/deswizzle dans `TextureUtils.cpp`.
Sur Apple ARM64, le temporaire de conversion 16→32 de la branche
**Apple/x64** est absent. En revanche, le chemin générique swizzled peut
allouer son `simple_array<U, sizeof(u128)>` temporaire sur ARM64 si les
conditions l'exigent. Son fast path, lorsque type/pitch/format/border le
permettent, convertit directement dans la destination et n'alloue pas ce
temporaire. Plusieurs autres `simple_array` sont de petites listes de
métadonnées sous le seuil. La couverture effective dépend donc des formats,
tailles et branches réellement parcourus dans la session.

`simple_array` possède aussi une capacité inline d'environ 64 octets et
n'appelle le wrapper que lorsqu'il doit dépasser sa capacité. Un bypass
important précède même le fast path de copie : `VKTexture.cpp` permet
byteswap, deswizzle matériel et zero-copy pour les images éligibles ;
`TextureUtils.cpp` évite alors le temporaire du chemin CPU générique.
Les buffers scratch Vulkan de ce chemin utilisent `vk::get_scratch_buffer`,
en dehors du hook NeoSwap.

Le format **R6G5B5 swizzled** constitue un exemple concret de chemin ARM64
avec temporaire CPU, traité avant le gate générique. Sans bordure, un
tampon 512 × 512 × 1 de ce chemin demande 1 Mio via `simple_array`, donc
atteint le seuil d'éligibilité. C'est un cas permettant de vérifier la
couverture, **pas une preuve que GoW III utilise ce format**.

Sont hors de ce hook : mémoire guest VM principale, code JIT, buffers LLVM,
allocations Vulkan/Metal GPU et allocateurs ordinaires qui n'utilisent pas
ce wrapper. **NeoSwap à zéro octet live ne prouve ni une absence de pression
mémoire ni un échec unique identifié** : petits buffers, branche sans
allocation, API absente, option désactivée, essai refusé ou blocs déjà
libérés peuvent expliquer cette observation.

Pour les distinguer, le delta local ajoute le getter **facultatif**
`rpcs3_ios_get_neoswap_client_stats`, sans changement de l'ABI principale 30
ni de la vtable NeoSwap ABI 1. Son contrat diagnostics fait 64 octets,
version 1, et expose les cumuls `skipped_small`, `missing_api`, `disabled`,
`eligible_attempts`, `failed_allocations`, `successful_allocations` et le
dernier résultat. Les compteurs `constinit` atomiques n'ajoutent pas de
constructeur statique ; les petits blocs sont rejetés avant l'API ou le
verrou du broker. Le snapshot est une observation cumulative sans verrou,
pas une transaction atomique entre tous ses champs. Ces compteurs ne sont
pas une quantité de RAM donnée et ne sont disponibles qu'avec un Core
reconstruit contenant le getter.

Le broker hôte examiné réserve une arène **virtuelle** `PROT_NONE` et mappe
des fichiers privés préalloués en `MAP_SHARED`. Le broker est compilé dans
l'hôte, pas dans chaque Core. Une réserve virtuelle ou un mapping de fichier
n'est pas une donation interprocessus de RAM. Le diagnostic actuel déclare
explicitement `memoryDonationSupported=false` et `donatedMemoryBytes=null`.

L'inventaire iOS initial, au commit NeoStation
`3ccde925`, a identifié les demandes `get-task-allow`,
`extended-virtual-addressing`, `increased-memory-limit` et
`increased-debugging-memory-limit`. Ce sont des déclarations de configuration,
pas la preuve de droits effectivement accordés à une IPA sur appareil.
Les helpers `.appex` présents dans cet inventaire servent à des transactions JIT via
NSExtension/debugger ; ils n'établissent pas un processus donateur durable.
Le `vm_remap` JIT observé crée des aliases dans le même processus. Aucun
transfert de pages entre un processus donateur et l'hôte n'est démontré par
ces chemins. Les nouveaux travaux de helper donateur conduits séparément
ne sont pas une validation rétroactive de cet inventaire. Les dépendances
binaires non matérialisées n'ont pas été
auditées comme si leur comportement était connu.

Une donation réelle pourrait, selon la propriété et la comptabilisation des
pages, réduire la pression résidente ou la contrainte jetsam de l'hôte.
Elle doit démontrer le processus donateur, ses droits accordés, le transfert
et sa durée de vie, la comptabilisation de l'hôte et du donateur, les erreurs
et la restitution sur appareil. Elle ne crée pas de capacité d'exécution
CPU ou GPU. Une éventuelle amélioration de FPS devrait ensuite être mesurée
séparément, sur la même scène, après avoir établi que la mémoire limitait
effectivement la progression.

Le dossier de donation réel demeure ouvert. Ni les tests de capacité
adossée aux fichiers, ni le getter, ni les trois correctifs v0.10.1 ne
valident cette donation ou un gain de performances physique.
