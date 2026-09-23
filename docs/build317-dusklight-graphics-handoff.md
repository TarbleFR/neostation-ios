# Build 317 — restitution des ressources graphiques de Dusklight

## Constat sur iPhone, Build 316

Le mainteneur confirme le retour des sons du menu hors mode silencieux. Le
correctif de propriété AVAudioSession de Build 316 reste conservé.

Les nouveaux journaux `neostation-dusklight(1).log` et
`RPCS3-diagnostic(8).log` montrent le même PID 54320 :

| Phase | Horodatage Unix | Empreinte physique | Plus grand trou visible |
| --- | --- | --- | --- |
| Avant Dusklight | 1790187239.522 | 501237984 octets | 764985344 octets |
| Première image | 1790187239.744 | 927484536 octets | 279281664 octets |
| Retour au menu | 1790187251.946 | 1380567744 octets | 218103808 octets |

Attention : ces trois parcours récursifs sont incomplets (`complete=0`) et
limités aux 256 premières lignes. Ils ne prouvent ni l'identité de chaque
allocation, ni une limite globale de 208 Mio. À 1790187261.692914, RPCS3
échoue à réserver son arène, après vérification du débogueur et du nonce.
Il n'a trouvé aucun candidat de 256 Mio dans sa plage basse.

La deuxième tentative, à 1790187271.7496018, échoue à `sandbox_paths` :
les setters RPCS3 refusent les chemins déjà renseignés lors de la première
initialisation échouée. C'est un défaut de récupération distinct, identifié
mais non modifié dans ce candidat Dusklight. RPCS3 et ses helpers gardent
strictement les identités de Build 316.

## Cause corrigée dans Dusklight

Le retour hôte arrêtait les images et l'audio mais gardait les cinq buffers
de transfert de 63 Mio et les quatre buffers partagés de 39 Mio au total :
354 Mio de stockage temporaire GPU restaient détenus entre deux sessions.
Les cibles de rendu et leurs caches restaient également présents.

Le nouveau retour, à une frontière d'image :

1. Suspend le jeu et attend le worker graphique.
2. Attend la fin du travail GPU puis chaque callback de mapping, avec un
   budget commun d'une seconde. En cas d'échec, conserve les ressources
   intactes ; aucun callback ne peut toucher une ressource libérée trop tôt.
3. Détruit explicitement les buffers temporaires et les cibles de rendu,
   libère leurs références et les caches de rendu associés.
4. Recrée les buffers à la première image suivante. La surface est recréée
   par le chemin Aurora existant. Les layouts, pipelines, textures durables,
   mémoire du jeu, documents/menu, préférences et sauvegardes sont conservés.

La version épinglée de Dawn (`1155e0ed531126f33a1279afa029349651ca1c93`)
libère son `MTLBuffer` dans `Buffer::DestroyImpl`. Son `WaitAny` attend la
fin du callback via `TrackedEvent::EnsureComplete`/`std::call_once`.
La barrière du worker seule n'offrait aucune de ces deux garanties.

Le relevé VM utilise désormais les régions de premier niveau, comme le
scanner RPCS3. Il ne confond plus les trous internes d'un sous-mappage
réservé avec de l'espace allouable. Les grandes régions restent journalisées
au-delà des premières lignes, avec mesure avant/après libération et indicateur
explicite de parcours complet.

## Vérification et limites

- Test exécutant les fonctions de production de création, mapping, attente,
  destruction et reprise : 100 cycles, références externes conservées,
  timeouts GPU/mapping, erreur GPU, callbacks annulés, appels répétés,
  conservation des layouts. Le pilote simulé sépare travail CPU/GPU.
- Tests existants de sessions, audio, menus, langue et fermeture des workers.
- Aucun nouveau texte utilisateur ; seuls les diagnostics techniques changent.
  Les contrôles existants dans les douze langues restent obligatoires.
- Ces tests prouvent le cycle de propriété, pas le placement réel des
  allocations Metal sur iPhone. La disparition du blocage RPCS3 reste à
  valider avec ce candidat. Ne pas annoncer une résolution définitive.

Les identités exactes de compilation et de livraison seront consignées après
réussite des validations natives et de l'IPA.
