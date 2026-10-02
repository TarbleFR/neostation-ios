# NeoSwap : cycle RAM → stockage → RAM pour des blocs CPU possédés

Chantier commencé le 2 octobre 2026 à la demande du mainteneur. L'objectif est
d'imiter le cycle fonctionnel du swap d'iPadOS dans NeoSwap : conserver des
données sur stockage, libérer leurs buffers RAM, puis restaurer leur contenu
à la demande. Le gestionnaire prend en charge les blocs que son client lui
confie explicitement, avec des accès protégés.

## Première étape livrée dans les sources

`ManagedSwap` réutilise le `Store` existant, sans changer son format ou le cache
SPIR-V. Une ressource logique est divisée en chunks bornés ; une acquisition ne
charge jamais tout l'objet. Chaque chunk possède une génération, une version
persistée et des leases de lecture ou d'écriture.

Le cycle est exécuté ainsi :

1. Une lease exclusive permet de modifier le chunk. Sa nouvelle génération
   invalide les anciens tokens ; aucune lecture concurrente n'est autorisée.
2. Le checkpoint copie un chunk stable, sauvegarde et synchronise sa nouvelle
   version. Il provoque ensuite une vraie relecture et compare les octets avec
   l'original encore présent en RAM.
3. Après réussite, l'éviction peut retirer le mapping RAM de l'original. Un
   chunk dirty, emprunté ou dont le checkpoint a échoué reste conservé.
4. Une acquisition froide relit la version vérifiée. Sa lease maintient les
   données en mémoire jusqu'à la fin de l'utilisation.

L'ancien checkpoint reste intact en cas d'échec de remplacement. Les erreurs
disque, refus de quota et exceptions après admission retirent le candidat
incomplet. Les codes et errno restent accessibles au client.

La pression mémoire peut libérer les chunks propres sans lecteur. Elle conserve
les modifications non sauvegardées et bloque les nouvelles éditions. Le
framework expose cette opération au propriétaire du contexte ; cette première
étape ne branche aucun nouveau watcher ni aucun consommateur dans RPCS3.

## Accès depuis C, Swift et le framework NeoSwap

`ManagedSwapABI.h` expose une ABI C indépendante : contexte opaque, objets,
générations, vues empruntées, checkpoint, éviction, restauration, pression et
statistiques. Les structures portent leur taille et leur version. Une vue ne
peut pas être écrasée alors qu'elle est encore empruntée.

Le header public est une copie vérifiée de la source canonique. La recette
existante de NeoSwap matérialise le nouveau moteur dans le pod et publie son
header, importable par Swift. Les ABI Core RPCS3 et shaders sont conservées.
La création d'un contexte est explicite : aucune allocation de démonstration
ni activation globale n'est ajoutée à l'application.

Les opérations bloquantes appartiennent à une queue utilitaire sérialisée.
`TryRead` ne réalise aucune entrée/sortie et renvoie un refus immédiat en cas de
contention ou de chunk froid. Les leases restent valides après retrait d'objet
ou destruction de contexte. Leur dernière libération ne rejoint aucun worker.

## Budgets et mesure

L'enveloppe configurée réserve la place des buffers possédés, du plafond dur
du Store, de la copie de checkpoint et du workspace de compression. Les
mappings survivant à un retrait restent comptés jusqu'à leur unmapping réel.

`resident_mapped_bytes` suit les mappings gérés, avec des réservations de
chargement ; ce compteur exclut le cache de fichiers du système, les autres
allocations du processus et le scratch codec, dont la borne est réservée
séparément. Il ne doit pas être affiché comme un gain de RAM physique sur iPhone.
Le footprint et la résidence du processus sont des mesures séparées.

La capacité logique est également séparée : les métadonnées d'un objet créé
ne sont jamais annoncées comme des pages RAM utilisées. La preuve native
remplit réellement 64 Mio non compressibles, chunk par chunk, puis vérifie
l'intégralité des octets restaurés.

## Validation

`run_managed_validation.py` compile et exécute les tests C++ et C avec Address
Sanitizer et Undefined Behavior Sanitizer. Il vérifie l'identité des contenus,
les limites, les pins, les générations périmées, la pression, la fermeture,
les erreurs write/fsync/read/corruption/troncature et une exception après
persistance, sans fuite de quota.

Sur macOS, la CI exécute également le client Swift contre la vraie bibliothèque,
lie les sources matérialisées pour iPhone arm64 et type-checke le client Swift
avec le SDK iOS 18 Simulator. Ces contrôles ne constituent pas un test physique
sur iPhone. Ils sont requis par le gate exact-SHA avant toute prochaine IPA.

Le rapport local est conservé dans
`neoswap-managed-swap-stage1-linux-proof.json`. Son `sourceCommit` nul désigne
une validation locale avant commit ; ses hashes identifient les entrées exactes.
Les preuves CI ultérieures portent le SHA du commit testé. LeakSanitizer est
indisponible dans le conteneur local ; ASAN et UBSAN restent actifs. La CI garde
ses réglages de sanitizer habituels.

Le premier passage CI Linux du commit `2cf8c787` a refusé un ancien test du
Store avant d'exécuter la nouvelle suite. Son admission utilitaire pouvait
renvoyer `busy` pendant que le worker détenait le verrou. Le harness conserve
les assertions d'intégrité, quota et pression, et borne les nouvelles tentatives
de ces admissions ; le moteur Store reste inchangé. Les accès rapides restent
testés sans attente. Ce correctif du harness nécessite sa propre validation CI.

## Intégration RPCS3 suivante

L'audit des sources exactes `22f1152783cef1f7e04af7b1c895173e28fd5b03`, après
matérialisation du patch canonique, identifie les sources GLSL conservées dans
`vk::glsl::shader::m_source` comme premier consommateur CPU possédé possible.
La création et compilation sont dans `VKProgramPipeline.cpp` ; les dumps
vertex/fragment ont lieu avant compilation. Les accès `get_source` et
`get_compiled` devront conserver un propriétaire ou une lease lors d'une
restauration. Le volume GLSL en jeu reste à mesurer.

Les upload heaps et textures examinés sont associés aux GPU/fences, les DMA
sont actifs, les instructions SPU sont relues par le dispatcher et les frames
vidéo peuvent être partagées avec le décodeur. Leur éviction demande un contrat
d'accès établi. Aucun gros cache froid de plusieurs centaines de Mio n'est
encore démontré. Le consommateur GLSL n'est pas modifié par cette étape.

La prochaine étape est l'intégration et la mesure d'un consommateur réel, puis
une politique automatique bornée de sauvegarde/éviction sur ses blocs froids.
La preuve générique de ce cycle ne démontre pas un gain en jeu, une correction
du gel RSX ou huit Gio de RAM physique disponible pour RPCS3.
