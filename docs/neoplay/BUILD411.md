# NeoPlay — Build 411

Candidat privé distinct de l'IPA 410 (`f5478b036878e5727a035086faff97d0581931cf`,
run `37541424599`, SHA-256 `89fa984e…`), qui reste la référence. Aucune
validation sur iPhone, Windows physique, Chromecast ou Apple TV n'est
revendiquée ; les preuves sont celles de la CI (harnais natif sur Simulateur,
récepteur Node, lecture Edge sur Windows, preuves macOS NeoSwap) et du
Simulateur iOS pour les donneurs.

## Son NeoPlay : plus de coupure au changement de qualité

Défaut mesuré après la 410 : au changement de palier vidéo, l'ancien encodeur
abandonnait le PCM en attendant la nouvelle configuration vidéo ; sur la
fixture native, neuf paquets PCM manquaient entre 5,0 et 5,3 s et le récepteur
comblait le trou par du silence.

| Mesure (lecture Edge CI de la fixture native à deux configurations) | Avant (récepteur 410, fixture 410) | Après (émetteur `86b3a053`) |
| --- | ---: | ---: |
| `underruns` (trames PCM de sortie manquantes à 48 kHz) | 10 915, soit 227 ms | 0 |
| `gaps` (trous PCM comblés par du silence) | 1 | 0 |
| `jumps` (sauts de l'horloge audio) | 1 | 0 |
| `skips` | 0 | 0 |
| Images présentées / décodées | 191 / 201 | 196 / 210 |
| Reconfigurations en place / récupérations décodeur | 1 / 0 | 1 / 0 |

Sur le PC Windows physique (autre session, fixture `bb347665`), le déficit PCM
mesuré avant correction était de 12 050 trames (251 ms) ; aucune mesure iPhone.

Correctifs :

- émetteur (`86b3a053`) : une seule session PCM (convertisseur et horloge
  d'échantillons) pour toute la capture, indépendante des encodeurs vidéo
  successifs ; la porte initiale ne s'ouvre qu'une fois la première
  configuration réellement transmise ; l'encodeur retiré ne bloque plus le son ;
- récepteur (Build 411) : une configuration ultérieure réutilise le moteur en
  cours (un seul nœud AudioWorklet, un seul anneau, une seule horloge) ; les
  images déjà décodées et celles encore dans l'ancien décodeur sont vidées puis
  présentées sur l'horloge partagée au lieu d'être jetées ; seul le décodeur
  vidéo est remplacé. Un redimensionnement ou le plein écran côté Windows ne
  fait que signaler une taille d'affichage : la taille encodée par l'iPhone ne
  dépend que de la capture et du plafond (test natif de politique), donc rien
  ne redémarre.

Vérifications CI ajoutées : fixture native à trois encodeurs (640×480 →
320×240 → 640×480, deux changements successifs sur une seule session PCM, PCM
pavé à 25 µs près à chaque transition, 240 images émises) ; lecture Edge de
cette fixture avec redimensionnement en cours de flux et assertions `gaps = 0`,
`jumps = 0`, `skips = 0`, `trimmed = 0`, `dropped = 0` (horodatages PCM
monotones), `underruns ≤ 50 ms`, un seul moteur et un seul nœud audio,
`reconfigures = configurations − 1`, images sur l'horloge audio
(`freeRun ≤ 3`) ; sélection du moteur testée en Node.

## RPCS3 et NeoSwap (sources postérieures à la 410)

- Warmup SPU : journal `SPUWARMUP begin/end` (durée en ms, compilations
  attribuées chargement/jeu), conditionné par `advanced.llvm_precompilation`
  (`precompile_discovered`) ; les objets ARM64 contenant des adresses propres
  au processus ne sont jamais persistés (branche vérifiée par le test
  `rpcs3_spu_warmup_test.py` avec le vrai préambule de compilation) ; God of
  War III reste le titre ciblé (six identifiants régionaux).
- Donneurs NeoSwap : acquisition prête uniquement, retrait différé borné,
  préparation progressive de 16 Mio ; iOS 18.5 Simulator (`d9589fa2`) : deux
  processus auxiliaires, 64 Mio réellement prêtés et vérifiés, onze contrôles
  de cycle de vie, refus, callbacks tardifs et nettoyage. Ces 64 Mio sont une
  validation fonctionnelle, pas l'objectif de capacité de NeoSwap.
- Preuve Vulkan 1 Gio : l'attente du registre donneur après la fin GPU suit
  désormais la tolérance de battement de la session (six secondes, deux fois,
  avec marge) au lieu de quatre secondes fixes manquées sur un runner chargé ;
  une session échouée interrompt l'attente avec un message propre ; la durée
  attendue est mesurée dans la preuve (`donorLedgerWaitMs`).
- Cœur RPCS3 emballé : run `37595624383` sur `d9589fa2` (le cœur de la 409 ne
  correspond plus aux entrées corrigées).

## Récepteur Windows

Mettre à jour `tools/neoplay-receiver` (`npm ci --ignore-scripts && npm start`)
et rouvrir la page dans Edge ou Chrome, puis Ready. « Receiving · frames »
confirme le protocole v2 ; exporter `window.neoplayDebug.diagnostics()` pour
les mesures (voir `RECEIVER-VALIDATION.md`).

## Ce qui reste à valider sur iPhone physique

Grésillement audible, flux iPhone → Windows réel (Wi-Fi, ReplayKit), warmup SPU
et prêts NeoSwap pendant God of War III, FPS et frametime. Aucun de ces points
n'est démontré par la CI ou le Simulateur.
