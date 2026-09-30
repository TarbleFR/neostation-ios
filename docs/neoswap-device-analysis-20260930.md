# NeoSwap — analyse des journaux appareil du 30 septembre 2026

Référence examinée : sources `618fb92a90285ea76547803828f8a0d66e257708`,
livrées dans la Build 369. Les sessions récentes du journal appareil portent
explicitement la **Build 368**, dont le Core RPCS3 et le chemin NeoSwap sont
identiques à ceux de la Build 369. Ces fichiers ne constituent donc pas un
test appareil de l'ensemble de la Build 369.

## Preuves reçues

- `RPCS3-diagnostic(20260930-143148).log` : 3 379 enregistrements JSON valides,
  avec un historique des Builds 363, 367 et 368. Les deux sessions Build 368
  contiennent 677 échantillons de performance, pour BLES00113 et BCES00510.
- `NeoSwap-v1.jsonl.previous` : 86 enregistrements JSON valides, tous du même
  PID hôte que la dernière session RPCS3 Build 368, du 30 septembre à
  15:56:43–15:56:54, heure de Paris. Il s'agit d'un fragment de journal après
  rotation, et non de toute la session.

Dans les deux sessions Build 368, `swap_attempts`, `swap_successes` et
`swap_rpc_shared_live` restent à zéro. Le compteur d'appels ignorés sous
1 Mio atteint 20 448 dans la première session, puis 469 638 dans la seconde.
Le journal NeoSwap confirme zéro demande RPCS3 et zéro allocation vivante.
Les huit donneurs finissent par préparer huit blocs vérifiés de 1 Mio,
mais aucun de ces blocs n'est prêté aux allocations du jeu.

## Deux défauts distincts examinés

Les sessions RPCS3 montrent des pertes et redémarrages de donneurs. Le fragment
NeoSwap contient l'erreur `donor_process_ledger_delta_exceeds_chunks` (3116),
y compris pour des slots dont le nouveau PID et la nouvelle génération sont
actifs et vérifiés. Le dictionnaire d'erreurs du plugin conserve l'erreur de
l'ancienne session après récupération : ce défaut de diagnostic est établi.
L'effacement doit attendre l'adoption, la vérification et les acquittements
du donneur actuel, sans laisser un callback d'une ancienne session changer
le diagnostic du nouveau donneur.

La mesure du helper soustrait séparément les catégories résidente et comprimée
de leur baseline, puis ramène chaque différence négative à zéro. Cette formule
peut rejeter un transfert entre catégories : avec une baseline de 32 Kio
résidents, un bloc vérifié de 1 Mio devenu comprimé peut être compté comme
1 Mio + 32 Kio, alors que l'augmentation totale reste exactement 1 Mio.
Le calcul doit compenser les diminutions entre catégories et conserver le
refus d'une augmentation totale réellement supérieure aux blocs vérifiés.
Les journaux ne contiennent pas les valeurs exactes au moment des anciens
échecs : ce défaut arithmétique est reproductible, mais son rôle dans chaque
échec 3116 observé reste à confirmer sur appareil.

## Objectif de 1 Gio réellement utilisé par RPCS3

Le raccordement actuel porte uniquement sur `rsx::aligned_allocator`, pour
les données CPU de 1 Mio ou plus. Les grosses allocations des heaps Vulkan
et du DMA utilisent un autre allocateur. Augmenter la préparation des donneurs
ou abaisser simplement le seuil ne raccorde pas ces allocations.

La piste suivante est l'import des blocs réellement donnés dans les buffers
Vulkan visibles par le CPU, en utilisant le chemin de pointeur hôte déjà
présent dans RPCS3. Elle nécessite une capacité explicite, distincte de l'ABI
CPU actuelle, la vérification de l'extension et de l'alignement sur l'appareil,
une acquisition RAM distinguée du repli par fichier, et une durée de vie liée
à la fin réelle des commandes GPU. Les prêts sont actuellement contigus et
bornés à 256 Mio par bloc ; atteindre 1 Gio doit correspondre au cumul de
buffers réellement utilisés, pas à un bloc de remplissage.

Le palier de 1 Gio en jeu n'est pas implémenté ni validé dans la Build 369.
Les corrections de mesure et de diagnostic sont préparées séparément de
ce raccordement et ne doivent pas être présentées comme une donation de 1 Gio.

La prochaine candidate est identifiée comme Build 370, pour conserver
l'identité de l'IPA Build 369 déjà livrée. Elle corrige le calcul des deltas
et l'effacement des erreurs après récupération vérifiée. Le test portable
couvre les transferts entre catégories, les dépassements réels, les débordements
et la preuve d'un nouveau bloc ; le simulateur exerce la méthode de production
du plugin avec de vrais donneurs et vérifie aussi les callbacks tardifs et les
erreurs encore actuelles. La validation native nécessite macOS/Xcode. Aucun
résultat appareil à 1 Gio n'est déduit de ces vérifications.

## Autres demandes de la mise à jour

- Dusklight 2.0.3 est intégré et son Core a été reconstruit dans la Build 369.
- Mario Kart Pad 0.7.2 n'est pas intégré : le Core 0.5.1 est conservé. La
  migration du runtime peut être préparée, mais sa validation complète exige
  un pack personnel `libkartpad_game.dylib` ABI 3 avec une empreinte compatible.
- Les corrections générales d'import de cheats Dolphin TXT/INI et ARMSX2
  PNACH sont présentes. Le dernier signalement GMXP70/r0 n'est pas confirmé
  comme résolu : le GCT binaire et son TXT source exacts ne sont pas disponibles.
- L'accès aux menus avec la manette a été annulé par le mainteneur.

## Preuve préalable à 1 Gio et compatibilité Metal

Une expérience CI séparée demande exactement 1 Gio de pages NONVOLATILE par le
même chemin NSXPC et les mêmes contrôles de headroom que les essais précédents.
Elle conserve les refus et valeurs réellement mesurées dans son rapport. Un
second essai à 128 Mio importe chaque chunk vérifié dans un `MTLBuffer` sans copie,
écrit sur les buffers avec une commande GPU, vérifie l'alias CPU et effectue
une relecture GPU. Les mappings restent vivants jusqu'à la fin des commandes
et à la libération des objets Metal ; une expiration termine le processus
de test sans libérer prématurément ses pages.

Le contrôle refuse de conclure à une donation GPU utile si les imports
augmentent fortement la charge mémoire du processus hôte. Un runner sans GPU
Metal est un échec de faisabilité documenté, pas une réussite simulée.
Cette expérience n'est compilée ni dans NeoStation ni dans le donneur livré.
Elle ne raccorde pas encore les heaps Vulkan de RPCS3 et ne démontre pas 1 Gio
en jeu sur iPhone. Le résultat matériel de cette preuve doit précéder le
raccordement des grosses allocations ; aucune réserve artificielle n'est
ajoutée au lancement du jeu.

Le premier essai (`1ad7c78`, run `36737143272`) a effectivement préparé
1 073 741 824 octets dans cinq chunks vérifiés. Le donneur mesurait
904 314 880 octets résidents et 169 426 944 octets comprimés. Le total est
exactement 1 Gio, mais l'assertion exigeant 1 Gio résident a échoué avant
l'import Metal. Ce résultat n'est pas une preuve de 1 Gio résident ni de RAM
utilisée par RPCS3. L'exigence résidente est conservée. L'essai Metal est ramené
à 128 Mio pour examiner séparément la compatibilité graphique. Le script
optionnel est aussi corrigé pour ne pas développer un tableau vide sous le
`nounset` du Bash 3.2 de macOS ; le chemin NSXPC habituel est revérifié.
