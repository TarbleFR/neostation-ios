# NeoSwap Guest Page Relay — candidate Build 372

Cette candidate adapte la stratégie du projet Guest Page Relay fourni par le
mainteneur, sous licence MIT. Elle ajoute une extension dédiée
`NeoSwapPageRelay.appex` et une interface mémoire commune à NeoStation. La
première intégration concerne exclusivement la mémoire émulée de RPCS3.

## Capacité et mémoire effectivement utilisée

L’extension crée seize objets mémoire nommés de 512 Mio avec
`MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED`, soit **8 Gio de capacité**.
Leur création ne touche pas toutes les pages et ne démontre donc ni 8 Gio de
RAM résidente, ni 8 Gio alloués par un jeu. Le relais n’ajoute aucune RAM physique
à l’appareil et la pression mémoire globale d’iOS reste une limite.

Les diagnostics distinguent la capacité retenue, les octets de mémoire émulée
actuellement empruntés, les différentes vues de ces mêmes octets et les mesures
réelles disponibles. Deux vues d’un même objet ne doublent pas la RAM donnée.
La résidence et la compression restent inconnues quand elles ne sont pas
mesurées ; elles ne sont pas remplacées par la capacité annoncée.

## Transfert et sortie du créateur

Le protocole emploie la connexion auxiliaire isolée de l’extension et un objet
`NSSecureCoding` transmettant un véritable droit Mach. Il ne modifie pas le
décodeur global de Foundation. Chaque échange valide le PID authentifié par
XPC, le nonce de la préparation, la génération, l’index et la taille de l’objet.

L’hôte conserve les droits avant d’acquitter leur réception. Il installe ensuite
un observateur noyau de sortie du processus, puis autorise l’extension à quitter
son propre processus. La capacité n’est publiée qu’après réception de
`DISPATCH_PROC_EXIT` pour le PID attendu. Une déconnexion XPC ou la fin d’une
requête d’extension ne suffit pas. Les échéances, annulations et réponses
retardées se terminent sans publier des droits partiels. Une nouvelle tentative
utilise une nouvelle session, un nouveau nonce et une nouvelle génération.

## Activation progressive dans RPCS3

Après la sortie observée du créateur, NeoStation vérifie **16 Mio** sur deux
vues du même objet : écriture complète, lecture cohérente et variation de
l’empreinte mémoire de l’hôte. Le relais est refusé si cette variation atteint
4 Mio, si une étape échoue ou si le nettoyage échoue. Ce contrôle de capacité
technique ne constitue pas une preuve de résidence de 8 Gio ou de stabilité en
jeu. Les prêts à RPCS3 ne sont activés qu’après ce contrôle.

Le nouveau backend sert les objets partagés de la mémoire émulée, avec des
intervalles alignés sur 64 Kio. Le même jeton conserve les mêmes pages à travers
ses différentes adresses. Les protections demandées par RPCS3 sont conservées ;
le relais n’expose pas de mappage exécutable. Il n’intervient pas dans le code
JIT. Les prêts Vulkan et le donneur NeoSwap v1 restent des chemins distincts.

Lorsque le relais n’est pas disponible, que son budget est épuisé ou que la
pression mémoire l’interdit, RPCS3 conserve son chemin d’allocation habituel.
Ce repli est possible avant la publication de la première vue d’un objet.
Ensuite, toutes ses vues doivent conserver le même support mémoire : un échec
ne peut pas être masqué en mélangeant des pages relayées et un fichier distinct.
Dolphin, ARMSX2, DuskLight, Mario Kart Pad, Flutter et UIKit ne sont pas branchés
sur cette nouvelle interface dans cette candidate. L’interface peut être
réutilisée ultérieurement après une adaptation propre à chaque moteur.

## Libération et échecs système

Les utilisateurs CPU/GPU doivent avoir terminé avant de libérer leurs vues.
Une vue à adresse fixe est remplacée atomiquement par une réservation sans
accès ; aucune étape intermédiaire ne crée de trou dans la plage de l’invité.
Un objet ne peut être réutilisé qu’après disparition de ses vues et effacement
de son contenu.

Les erreurs du noyau conservent la propriété des ressources. Le nettoyage des
vues libres et des droits peut être réessayé. Si le nettoyage final d’une vue à
adresse fixe échoue, cette vue et son objet sont mis en quarantaine pour la
session entière : une reprise tardive ne doit jamais écraser une adresse que
RPCS3 aurait réutilisée. Les compteurs exposent ces ressources en attente ; elles
ne sont pas annoncées comme libérées.

## Niveau de validation

Les tests portables vérifient les règles d’allocation, les alias, le repli, la
pression, la réutilisation et les erreurs de nettoyage. Ils ne démontrent pas
la comptabilité mémoire d’iOS.

La suite macOS prévue utilise les vrais objets nommés et la même négociation
XPC. Un premier scénario attend la sortie effective du créateur, écrit
intégralement 1 Gio, relit une seconde vue, mesure la résidence et l’empreinte
hôte, puis vérifie libération et effacement. Un scénario distinct prépare
les seize objets, soit 8 Gio de capacité, et écrit 64 Kio par objet, donc
**1 Mio réellement écrit au total**. Il vérifie les alias et leur libération ;
il ne démontre pas que les 8 Gio sont résidents. Le relancement est vérifié
après fermeture de ce second créateur. Une suite Simulator vérifie séparément le lancement de l’extension
iOS. Les résultats sont attachés au SHA exact de la candidate ; ce document ne
présume pas leur réussite.

**Validation sur iPhone et en jeu : en attente.** Une compilation réussie ou un
résultat macOS/Simulator ne démontre pas le comportement de God of War 3 sur
appareil, la quantité réellement prêtée au jeu, une limite mémoire supérieure
ou un gain de performances. Les journaux de la Build 372 devront permettre de
mesurer ces points, y compris après arrêt et relancement du jeu.
