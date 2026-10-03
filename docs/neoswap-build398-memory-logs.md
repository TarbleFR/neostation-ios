# Build398 — mesures de pression et reprise du packaging

Le cœur RPCS3 corrigé reste celui du commit
`2e18a46d3f7733ed7ae8f237615e2c7a4fd2501d`, workflow `37103098994`,
SHA-256 du binaire `af20dcc0e8619c8f8ce7a1aaecd3a4870cda9db39e1c23f1913fb4b161abb0ed`.
Ses 52 entrées restent inchangées. La reprise concerne le host, pas une
nouvelle reconstruction du cœur.

L'assemblage `37103294564` a échoué avant la compilation de l'application :
Flutter lance CocoaPods même avec `--config-only`, alors que NeoPlay exige
déjà iOS18 et que le host généré avait encore une cible inférieure.
Le configurateur NeoPlay applique désormais ce plancher au Podfile, à Runner
et au framework Flutter avant Flutter/CocoaPods, puis après les générateurs
historiques. Il ne baisse jamais un plancher supérieur et ne modifie pas les
targets des émulateurs, des helpers JIT ou du donneur.

## Journal de session

Le timer et la queue de diagnostics existants sont réutilisés. Pendant une
session RPCS3, un relevé est écrit environ chaque seconde, même sans prêt
NeoSwap actif. Les transitions début/fin de session et de pression système
sont enregistrées au prochain passage du timer (environ 250 ms). Les rafales
de pression sont coalescées, avec compteurs d'événements et de transitions.
Hors session, le rythme historique de deux secondes reste conditionné à
l'activité réelle des allocateurs. Il n'y a aucun sondage par image.

`Documents/Diagnostics/NeoSwap-v1.jsonl` et sa génération `.previous`
contiennent au maximum 2 MiB chacun ; une ligne supérieure à 64 KiB est refusée.
L'erreur technique reste disponible dans le snapshot. Les relevés associent :

- horodatage, PID, build, séquence/durée de session et pression système ;
- `TASK_VM_INFO` : empreinte, taille résidente et ledger compressé, avec résultat kernel ;
- pics observés et variation signée de l'empreinte ; une mesure indisponible reste inconnue ;
- headroom du processus, prêts réellement vivants et capacités virtuelles séparées ;
- diagnostics existants `shaderStorage`, dont le cycle GLSL RAM–stockage–RAM et ses erreurs/I/O.

Le pic est un **pic échantillonné**, pas une garantie de capturer chaque
transitoire. Le ledger compressé n'est pas assimilé à de la RAM physique
disponible. Ni une capacité virtuelle ni le budget de stockage ne deviennent
de la RAM dans ces mesures.

## Essais

Les tests natifs injectent des séquences de pression et de mesures pour
vérifier cadence, isolation des sessions, pics, variations négatives, erreurs
de mesure et coalescence. Le probe iOS18 Simulator exécute le véritable
plugin/timer avec une session signalée mais sans émulateur et sans allocation
vivante, puis vérifie les lignes et la rotation bornée du journal.

Ces tests ne démontrent ni une partie RPCS3 réelle, ni un gain de RAM/FPS,
ni une correction du freeze sur iPhone. Pour reconnaître des motifs utiles,
il faut ensuite des journaux du même jeu sur l'appareil réel : lancement,
chargement, quelques minutes dans une zone reproductible, retour au menu,
puis relancement. Comparer les pics/headroom, événements de pression,
archivages/restaurations et refus entre ces phases. Aucun apprentissage
automatique ni changement autonome de politique n'est activé.
