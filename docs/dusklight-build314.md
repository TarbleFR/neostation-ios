# Build 314 — navigation des menus Dusklight

## Constat vidéo et sources

La vidéo du 23 septembre montre les deux commandes UIKit (engrenage et retour)
superposées aux croix de fermeture natives des pages Succès et Mods. Le compteur
FPS recouvre aussi une partie du premier onglet. Le callback de l’engrenage
remettait systématiquement MenuBar au premier plan, même devant un sous-menu
ouvert : il ne constituait pas une commande de reprise.

## Correction ciblée

- Une seule commande UIKit pour ouvrir le menu, seulement hors menus natifs.
  Masquage dès le premier appui, puis synchronisation à chaque image avec les
  documents réellement affichés, animations de fermeture comprises. Pas de
  repositionnement approximatif ni de second bouton Quitter superposé.
- Les croix natives restent accessibles. Fermer une page revient au niveau
  précédent ; « Reprendre le jeu », la croix du menu principal et son action
  Annuler manette ferment la pile et libèrent les commandes de jeu. Les choix
  initiaux obligatoires et l’écran pré-lancement ne sont pas contournés.
- L’engrenage ignore une demande tardive si une fenêtre native est déjà visible :
  il ne réordonne plus Settings/Mods derrière la barre principale.
- « Retour à NeoStation » reste dans le menu, avec confirmation. Sa confirmation
  ferme aussi le menu avant de suspendre la session ; le même disque reprend
  directement le jeu, sans ancien sous-menu laissé devant.
- Le compteur FPS est masqué pendant les menus, sans modifier sa préférence.
- « Reprendre le jeu » est traduit dans les douze catalogues NeoStation et envoyé
  au moteur via le canal ABI 3 existant. Les libellés préexistants upstream ne
  sont pas réécrits par ce correctif.

Le cycle de vie 313 (moteur conservé, reprise du même disque, nouvelle image
requise), les sauvegardes et les cœurs RPCS3/Dolphin/ARMSX2 restent inchangés.

## Vérifications

Le test `dusklight_menu_test.py` compile les fonctions de production d’ouverture,
de reprise, de fermeture de pile et de visibilité avec des documents RmlUI
simulés. Il couvre 100 cycles, sous-menus imbriqués, appuis doubles/tardifs,
animations, blocage des entrées et garde du premier paramétrage. Les assertions
complémentaires contrôlent le câblage UIKit (bouton unique, 44 points, safe area),
le masquage FPS et les clés des douze catalogues. Il est bloquant en CI native
et hôte, en plus des tests 313 conservés. Il ne simule pas le hit-testing iOS.

## Validation iPhone requise

1. Ouvrir l’engrenage : disparition du bouton UIKit et du compteur FPS.
2. Parcourir Settings, un sélecteur, Succès puis Mods ; vérifier que chaque
   croix est visible et utilisable, y compris après rotation et avec encoche.
3. Fermer la page puis « Reprendre le jeu » : retrouver les commandes tactiles
   (si activées), déplacement et son ; répéter au moins cinq fois rapidement.
4. Ouvrir avec une manette, revenir par B puis fermer le menu principal.
5. Annuler le retour à NeoStation : rester dans Dusklight. Confirmer le retour,
   relancer le même disque : reprendre sans fermer l’application.
6. Arrière-plan/premier plan depuis un sous-menu : aucune superposition ni
   touche bloquée. Premier lancement vierge : choix du preset toujours requis.

Une CI verte n’est pas une validation de ces interactions sur iPhone.
