# Build 288 — VPN, JIT and lancement RPCS3

## Périmètre

Cette révision ne modifie aucune source de suppression, d’import, de base de
données ou de nettoyage RPCS3. La suppression de jeux, déclarée fonctionnelle,
reste hors périmètre.

## Causes établies

### Activation du VPN interne

Le journal `app(20260919-145520).log` montre que la dernière installation ne
reste pas simplement en attente : NetworkExtension termine chaque activation
avec `NEVPNConnectionErrorDomain(12)`, soit `pluginFailed`. Le premier échec
apparaît après un changement de conteneur d’application, alors que le manager
réutilise volontairement le profil système persistant. Dans cet état, resauver
le même `NETunnelProviderManager` conserve son association défectueuse avec le
provider de l’installation précédente.

Le manager conserve le profil stable dans le cas normal. Après le seul échec
`pluginFailed`, il arrête et supprime uniquement le profil NeoStation fautif,
en crée un nouveau avec l’identifiant du provider effectivement installé, puis
réessaie une seule fois dans la même commande ON. Tout autre échec garde sa
cause native et aucun profil étranger n’est supprimé.

### Lenteur avec LocalDevVPN

`LocalJitTunnelService.ensureRunningForJit()` attendait d’abord une activation
du VPN interne déjà en cours, puis testait `10.7.0.1:49152`. Une route
LocalDevVPN déjà utilisable pouvait donc attendre les 45 secondes de la
commande interne avant d’être reconnue.

Le préflight teste maintenant la route en premier. Il n’attend l’activation
interne et ne reteste la route que si le premier test échoue. Le préflight ne
démarre, n’arrête et ne reconfigure toujours aucun VPN.

### Crash entre StikJIT et le Core RPCS3

Le journal contient plusieurs séquences où `RPCS3 internal JIT prepared` est
immédiatement suivi d’une nouvelle initialisation de NeoStation, sans message
`Core initialized`. Les diagnostics natifs correspondants s’arrêtent à la
première boucle Universal. L’ancien signal `Handling signal 1` et son délai de
250 ms ne prouvaient pas que debugserver avait repris la cible.

Build 287 a remplacé ce délai par un BRK authentifié et une réponse nonce, mais
effectuait encore cette preuve dans `prepareJit`, avant le retour Flutter, la
lecture du statut JIT et un second appel de plateforme. La preuve pouvait donc
être vraie puis devenir périmée avant `dlopen`.

Build 288 réserve la preuve BRK/nonce au thread du chargeur, après la sélection
du dylib et immédiatement avant `dlopen`. Le Core n’est pas chargé si le PID,
la session active, `P_TRACED`, la réponse nonce ou la reprise du thread ne sont
pas confirmés. La séquence n’utilise plus de délai fixe ni de message de log
comme signal de disponibilité.

## Diagnostics ajoutés

- durée du préflight de route et transport interne/externe ;
- durée de connexion du helper et de l’attachement debugserver ;
- jalons persistants pour préparation JIT, preuve nonce, frontière `dlopen`,
  initialisation du Core, détachement et boot ;
- durée de chaque phase jusqu’au retour de `boot_game` ;
- lecture du vrai fichier `RPCS3-milestones.log` dans le rapport de support
  (le code précédent lisait seulement `RPCS3-diagnostic.log`).

## Non-régression

- machine d’état VPN : reconstruction après `pluginFailed`, réussite du profil
  neuf, et arrêt après un seul retry si le nouveau provider échoue aussi ;
- LocalDevVPN : une route externe vivante ne dépend pas d’une activation
  interne pendante ; une route absente attend cette activation puis est retestée ;
- script Universal : identité PID, nonce, avance PC, écriture registre et vraie
  reprise, avec cinq chemins de rejet ;
- handoff Core : l’appel de preuve final est ordonné avant `dlopen`, et le
  mécanisme `Handling signal 1` + 250 ms reste interdit ;
- Core RPCS3 et provider PacketTunnel : leurs binaires donneurs restent ceux
  déjà validés, tandis que seuls les contrôleurs hôtes sont recompilés.

Les tests macOS et la compilation IPA vérifient les contrats et le binaire
produit. La stabilité matérielle finale doit encore être confirmée sur iPhone
avec les nouveaux jalons, car un runner CI ne peut pas reproduire debugserver,
NetworkExtension et le chargement JIT réel d’iOS 26.
