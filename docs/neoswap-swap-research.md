# NeoSwap : reprise isolée sur `swap`

Point de départ : hôte Build401 `905461854998c65e1b884cabfedd7b46060c701b`.
Les références `experimental`, `main`, `backup`, les cœurs et les helpers JIT
ne sont pas modifiés par ce chantier. Cette candidate est une étape de recherche,
pas une validation de stabilité sur iPhone.

## Périmètre exclusivement RPCS3

Les seuls clients acceptés par l'allocateur, les sessions et le relais sont ceux
portant l'identifiant RPCS3. Les identifiants historiques des autres cœurs et du
probe restent réservés dans l'ABI v1, sans allocation, enregistrement ni demande
de donneur. Une configuration qui tenterait de les activer est refusée.
Dolphin, ARMSX2, DuskLight, KartPad et les autres ports ne sont pas intégrés.

Le relais ne démarre plus à l'ouverture de NeoStation : seul l'appel explicite
de préparation RPCS3 le lance. Après une session, la maintenance inactive ne
relance aucun helper. Elle libère le support RPCS3 devenu inutilisé ; les alias
RPCS3 encore vivants conservent leur propriété jusqu'à leur fin effective.
La télémétrie de pression du jeu et les warnings persistants sont centrés sur
les sessions RPCS3. Les vérifications synthétiques de fichiers restent dans
les builds de test ; elles ne sont ni proposées ni exécutées dans l'application
distribuée. La structure ABI et le Core RPCS3 épinglé restent identiques.

## Résultat de l'audit du fichier fourni

Archive : `guest-page-relay-main(1).zip`, SHA-256
`f4d8425956a0f59f8dd126901690b5b863045054f3c272f076fccd2685d12426`.

Le framework MIT crée des objets mémoire nommés dans une extension avec
`MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED`. Les droits Mach sont transmis à
l'hôte, puis les mêmes pages sont mappées dans les adresses appartenant à
l'émulateur. Le créateur quitte après le transfert. Les workers sont des threads
de préparation/maintenance ; les extensions sont des processus distincts.
Leur nombre ne multiplie ni la RAM physique ni le stockage disponible.

Ce fichier ne contient ni pager de stockage, ni sélection des pages froides,
ni restauration sur faute mémoire, ni compression. Ses segments de 512 Mio sont
une capacité virtuelle. Seuls les accès aux données et les mesures noyau peuvent
établir la résidence et la comptabilité. Son README annonce explicitement une
absence de validation sur appareil.

Le fichier Swift utilise un lancement privé d'extension et une modification du
décodeur Foundation. NeoStation possède déjà une adaptation Objective-C++ du
relais. Elle conserve les protections et alias RPCS3, valide la session/PID/droits,
observe la sortie du créateur et évite cette modification globale du décodeur.
Réimporter une deuxième instance Swift ne serait pas une intégration utile.
L'utilisation exacte de ce même fichier dans une version distribuée de MeloNX
n'est pas établie par l'archive fournie.

## Chemins conservés et améliorations

| Données | Gestion | Condition de libération |
| --- | --- | --- |
| Mémoire invitée RPCS3 active | Relais Mach, mêmes pages pour tous les alias | Tous les utilisateurs ont fini ; les alias fixes sont remplacés atomiquement par une réservation |
| Buffers CPU RSX admissibles | Prêts du donneur existant ou allocation habituelle | Fin de propriété du buffer ; pas de migration d'un pointeur actif |
| Sources GLSL après création du module | Copie possédée bornée, checkpoints vérifiés par blocs de 64 Kio | Copie hôte libérée seulement après persistance vérifiée de tous les blocs |
| Anciens pixels VDEC logiciels exclusivement possédés | Archivage seulement quand le headroom mesuré est faible | Même validation ; original conservé si admission refusée |
| Données chaudes / buffers encore référencés | RAM, sans éviction automatique | Fin des références effectives |
| Cache tiède | Compression bornée si utile | Décompression et restauration vérifiées avant consommation |
| JIT, modules GPU, données mutables invitées | Chemins existants | Aucun nouveau pager sur ces données |

RPCS3 conserve l'allocation habituelle lorsque la préparation du relais échoue
avant le premier mapping d'un objet. La disponibilité du relais n'est plus une
condition fatale de lancement. Une erreur d'ABI/binder reste fatale. Aucun objet
publié ne mélange ensuite des alias relayés et un support fichier distinct.

Les seuils d'admission VDEC dépendent de la RAM physique : entrée à RAM/8,
bornée entre 512 Mio et 1 Gio ; sortie à 1,5 fois ce seuil. Une mesure inconnue
ou trop ancienne interdit l'admission. Les warnings/pression critique suspendent
les nouvelles admissions ; les snapshots déjà acceptés restent restaurables.
Cette adaptation ne prétend pas connaître le seuil jetsam effectif de l'appareil.

## Comparaison reproductible

Trois profils sont fixés dans `Info.plist` avant signature. Ils sont immuables
pendant le processus et ne créent aucune nouvelle option utilisateur.

| Profil | Relais invité | Donneurs CPU | Archivage |
| --- | --- | --- | --- |
| `baseline` | Désactivé ; support ordinaire | Aucun lancement | Désactivé |
| `relay` | Activé si vérifié | Aucun lancement | Désactivé |
| `integrated` | Activé si vérifié | Un donneur initial pour un consommateur admissible, sinon demande réelle ; graine 16 Mio | Automatique sur les titres déjà admissibles |

Dans le profil explicite `integrated`, la cible du pool CPU est constituée des
prêts actifs plus 32 Mio de marge, arrondie par 16 Mio, avec le plafond existant
de 5 Gio. Sans consommateur admissible ni demande réelle, aucun donneur n'est
lancé et aucun délai de préchauffage n'est imposé au jeu. Pour un consommateur
admissible à vide, cela représente une cible de 32 Mio plutôt que 512 Mio. Une
véritable demande de buffer prime sur la petite graine de démarrage. Les
réservations des requêtes en vol et les refus de pression globale sont conservés.
La capacité de relais de 8 Gio reste une capacité, pas un objectif de résidence.
Un paquet sans profil explicite conserve les préférences de stockage et
l'ancienne politique du pool CPU.

Après génération du projet iOS et avant signature, sur `swap` uniquement :

```bash
python3 build-utils/configure_neoswap_research.py --mode baseline
# Refaire l'assemblage depuis le même SHA avec --mode relay puis --mode integrated.
```

Protocole appareil : même téléphone, version iOS, jeu, sauvegarde de départ,
réglages et état des caches. Faire trois passages courts de chaque profil,
puis des sessions de 30 à 60 minutes ; alterner les profils pour limiter les
biais de chauffe. Inclure retour au menu, arrêt/reprise, relancement et passage
dans un autre émulateur. Conserver les logs dès la fin du passage. Ne pas
effacer les sauvegardes ou caches comme moyen de contourner un défaut.

La comparaison accepte des fichiers courants et tournés, déduplique les lignes
et refuse plusieurs sessions non sélectionnées, des profils mélangés, une
baseline avec prêts actifs ou des identités source/OS/RAM incompatibles :

```bash
python3 tools/compare_neoswap_sessions.py \
  --baseline baseline/NeoSwap-v1.jsonl.previous baseline/NeoSwap-v1.jsonl \
  --baseline-rpcs3 baseline/RPCS3-diagnostic.log baseline/RPCS3-milestones.log \
  --candidate integrated/NeoSwap-v1.jsonl.previous integrated/NeoSwap-v1.jsonl \
  --candidate-rpcs3 integrated/RPCS3-diagnostic.log integrated/RPCS3-milestones.log \
  --candidate-operations integrated/NeoSwap-operations.jsonl \
  --title BCES00510 --output comparison.json
```

## Télémétrie et limites explicites

`NeoSwap-v1.jsonl` distingue footprint, résidence, compression, headroom du
processus, pages libres/actives/inactives/wired/compressées du système, capacité
retenue du relais, prêts effectivement utilisés, pool préparé et allocations
fichier. Il ajoute profil/SHA, warnings UIKit, état thermique et compteurs
`TASK_EVENTS_INFO` : faults, pageins, COW. Le compteur `zeroFills` reste inconnu
car cette API ne le fournit pas. Ceux-ci sont des compteurs
noyau du processus, pas des restaurations NeoSwap.

`NeoSwap-operations.jsonl` enregistre session, objet, domaine, index de bloc,
séquence, temps monotone, octets logiques, durée, résultat et errno : admission,
checkpoint vérifié/éviction, libération de snapshot, lecture RAM, restauration,
retrait, pression et échec avec copie RAM conservée. Chaque bloc restauré a son
index ; une erreur de lecture identifie le bloc fautif. Les événements portant
sur l'objet entier ont `chunk: null`, sans être attribués artificiellement au
bloc zéro. Domaine, résultat et errno ont aussi une description textuelle.
Le comparateur rattache les opérations à l'epoch d'archive observé et signale
les événements exclus d'une autre session. Les métriques agrégées
donnent séparément volumes lus/écrits, compression/décompression, attente de la
file de restauration et temps du travail. Les décisions VDEC ont une raison
technique explicite. La journalisation n'effectue pas d'I/O dans l'admission
Core ou dans la FIFO de restauration ; elle utilise le worker de diagnostic.

Les buffers d'événements ont une borne de 512 entrées ; la consommation est
bornée et les événements perdus sont comptés explicitement. Une trace saturée
n'est donc jamais présentée comme exhaustive. Chaque famille de logs conserve
deux fichiers de 16 Mio, soit au maximum 64 Mio pour les deux familles NeoSwap.
Une rotation peut supprimer le début d'une longue session : le comparateur le
signale. Les erreurs d'écriture restent visibles.

`coreBootCallSeconds` utilise les milestones réels `game_boot_begin` et
`game_boot_return`, avec un statut de succès. Cette durée mesure l'appel du
Core ; elle ne comprend pas tout le lancement de l'application, la préparation
du relais avant session ou le délai jusqu'à la première image jouable.

Les FPS proviennent du producteur Core existant à 1 Hz, sans deuxième appel au
getter. ABI30 ne fournit pas de timings par frame. `frameTimeP95Ms` et
`stutterCount` restent inconnus ; 1000/FPS n'est pas présenté comme un frametime.
Une fin de session absente ne prouve pas un jetsam/OOM. La cause d'une terminaison
brutale exige le rapport iOS correspondant ; la dernière pression ne suffit pas.
L'instrumentation ne connaît pas l'origine de toutes les allocations internes
LLVM/RSX/FFmpeg. Une hausse non attribuée doit rester explicitement inconnue.

## Validation et prochaine étape mesurable

Tests locaux exécutés : 64 Mio de GLSL et environ 63 Mio de pixels synthétiques,
RAM → fichier → RAM à l'identique, erreurs de persistance/restauration, epochs,
pression/reprise, priorisation des demandes, journal borné et comparaison.
AddressSanitizer et UndefinedBehaviorSanitizer sont actifs. Le contrôle des
fuites Linux est indisponible dans l'environnement local ; les checks Apple
restent obligatoires. Ces tests n'exécutent pas un jeu RPCS3 sur iPhone.

La CI `swap` conserve les checks existants du broker/donneur/relais/stockage et
ajoute les profils, la compilation du plugin complet pour iPhone arm64 et trois
exécutions du service sur iOS18 Simulator. Les résultats sont liés au SHA exact.
Le manifeste Core reste byte-for-byte identique (SHA-256
`bacfc4ebe194ea6469b60f38e3067100357c3e111ffc02c8e5d533d3bf56a59b`).

Avant toute promotion : contrôles Apple réussis, paquets de comparaison du même
SHA, mesures physiques reproductibles, gain de footprint/pression établi,
absence de nouvelle corruption ou de crash sur session longue, coût de lancement
et FPS acceptable, puis vraie instrumentation des frametimes pour conclure sur
les stutters. Aucun résultat synthétique n'autorise automatiquement une fusion
sur `experimental` ou `main`.
