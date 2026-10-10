# Moteur libretro intégré : PSP, 3DS, skins par console, shaders, format d'écran et commandes

Conception du cycle demandé le 9 octobre 2026 (branche `Claude`, base `a5650b9`).
Les en-têtes `packages/libretro_internal_bridge/ios/Classes/*.h` cités ici sont le
contrat entre les modules ; ce document fixe les règles de comportement.

Rien de ce qui suit n'a été exécuté sur un iPhone. Les chemins OpenGL ES (PPSSPP)
et Vulkan (Azahar) n'ont jamais tourné sur un appareil.

## 1. État des lieux (vérifié dans les sources)

| Sujet | Existant | Manque |
|---|---|---|
| PSP | Cœur PPSSPP intégré (GLES3), profil `psp`, ressources PPSSPP embarquées, aucune route vers l'app PPSSPP | Clé de console canonique (un nom de dossier alias peut renvoyer un jeu vers RetroArch pendant un scan), skin, format, shaders, commandes |
| 3DS | Cœur Azahar intégré (Vulkan), profil `3ds`, pointeur | Accès sans jeu, deux écrans séparés, portrait, tactile après changement d'affichage, shaders (Vulkan présente hors Metal) |
| DS | Cœur DeSmuME, profil `nds` | Tactile : `desmume_pointer_type` vaut `mouse` par défaut, l'hôte n'envoie que le pointeur |
| Skins | Superposition codée en dur par profil, paysage seul | Modèle, skins par console, import `.deltaskin`, aperçus |
| Shaders | Filtre lisse/net global | Post-traitement réel |
| Format d'écran | Rapport du cœur seulement | Original, 4:3, 16:9, 16:10, Étiré, par console et par jeu |
| Commandes | Correspondance manette fixe | Réaffectation manette et tactile, position, taille, opacité |

## 2. Principes

1. **Trois couches séparées pour les commandes** (`LibretroInputMap.h`) : commandes
   logiques de la console (vocabulaire Delta/Provenance), représentation dans le
   skin (`LibretroSkinItem.inputs`, réaffectations), transmission au cœur
   (RetroPad, axe analogique, pointeur ou action NeoStation).
2. **La console, pas le cœur, porte les préférences.** `LibretroSystemBinding.console`
   (Dart) donne une des 17 consoles : `nes snes gb gbc gba md mcd 32x sms gg sg1000
   arcade nds n64 psx psp 3ds`. Game Boy, Game Boy Color et Game Boy Advance ont
   chacune leurs préférences ; changer de cœur ne touche pas au skin.
3. **Priorité des réglages** : réglage du jeu, sinon réglage de la console, sinon
   réglage par défaut de NeoStation (`LibretroFrontendStore`). Chaque page du menu
   indique d'où vient la valeur et permet d'enregistrer pour la console ou pour
   ce jeu, et de rétablir les valeurs par défaut.
4. **Un seul chemin d'image** : logiciel, OpenGL ES et Vulkan passent tous par
   `LibretroMetalPresenter` (Vulkan par copie en mémoire hôte,
   `LibretroVulkanRenderer.h`). Écrans multiples, format, shaders et rotation
   s'appliquent donc à tous les cœurs. Si la copie Vulkan ne peut pas être
   préparée, l'ancien affichage reste en secours et le menu indique que shaders et
   écrans séparés sont indisponibles.
5. **Écriture unique des préférences** : seul le code natif écrit les fichiers
   `Documents/Libretro/Config/Frontend/<console>.json` ; Dart passe par le canal.
6. **Aucun texte natif** : toutes les étiquettes arrivent traduites de Dart
   (`uiText`), dans les douze langues.

## 3. Skins

### Modèle et sources

- Skin par défaut de chaque console (`LibretroDefaultSkins`), dessiné en vecteurs,
  inspiré des commandes d'origine (couleurs et symboles de la console), généré à la
  taille exacte de la vue : il s'adapte à tout iPhone et iPad, en portrait et en
  paysage. Portrait : jeu en haut, panneau de commandes opaque dessous. Paysage :
  jeu sur toute la zone sûre, commandes translucides sur les côtés.
- Skins importés `.deltaskin`, `.manicskin` ou `.zip` : analysés par
  `+[LibretroSkin skinWithDirectory:consoleRegions:errorCode:]`, seul analyseur
  (natif, testé sur macOS). Le format suivi est celui du code réel de
  Delta/Provenance, pas celui du wiki (voir le rapport d'étude) :
  `representations.{iphone|ipad}.{standard|edgeToEdge}.{portrait|landscape}`,
  `mappingSize`, `assets` (`resizable` PDF ou `small|medium|large`), `items`
  (`inputs` tableau, objet `up/down/left/right`, objet `x/y` ; `frame`,
  `extendedEdges`, `thumbstick`), `screens` (`inputFrame`, `outputFrame`) ou
  `gameScreenFrame`, `translucent`.
- Le format des images est détecté par leur contenu (`%PDF`, PNG, JPEG), jamais
  par la clé.

### Choix de la représentation

Appareil (`ipad` ou `iphone`), type d'écran (`edgeToEdge` si la zone sûre du bas
est non nulle), orientation. Repli d'appareil comme Delta ; **aucun repli
d'orientation** : si l'orientation manque, le skin par défaut de la console est
utilisé pour cette orientation, et l'interface l'annonce.

### Écrans DS et 3DS

Le cœur rend toujours les deux écrans empilés : NeoStation impose pendant la
session `desmume_screens_layout=top/bottom`, `desmume_screens_gap=0`,
`desmume_pointer_type=touch` (corrige le tactile DS) et
`citra_layout_option=default`, `citra_swap_screen=Top`. Les régions sont fixées
dans le catalogue Dart : DS haut `[0,0,1,0.5]`, bas `[0,0.5,1,0.5]` ; 3DS haut
`[0,0,1,0.5]`, bas `[0.1,0.5,0.8,0.5]` (400×240 au-dessus de 320×240 centré).
NeoStation recadre puis place chaque écran : dispositions « empilés », « côte à
côte », « grand écran du haut », « écran du haut seul », « écran du bas seul », et
inversion. Le réglage DeSmuME « Disposition des écrans » quitte les réglages
d'émulation : il est remplacé par cette disposition NeoStation, qui ne casse plus
le tactile.

Pour les skins importés : DS suit les `inputFrame` Delta (256×384) ; 3DS ignore
les `inputFrame` (incohérents chez Manic) et attribue les rôles par l'écran
tactile ; PSP et autres n'utilisent un `inputFrame` que s'il tient dans l'image
nominale de la console.

### Tactile

Toute touche dans l'écran tactile (rectangle réellement dessiné, publié par le
présentateur à chaque image) est convertie par `LibretroPointerFromPoint` en
coordonnées sur l'image complète du cœur : le tactile reste juste après rotation,
changement de format, de disposition ou de skin. Une manette physique masque les
boutons tactiles mais laisse l'écran tactile actif.

### Persistance

Sélection par console et par orientation (`skin.portrait`, `skin.landscape`),
exception possible par jeu. Les skins importés sont stockés dans
`Documents/Libretro/Skins/<id>/` avec `neostation-skin.json` (nom, auteur, source,
licence, consoles, orientations, remarques, SHA-256, date). Supprimer un skin
efface aussi ses sélections (`forgetSkin`).

### Import et catalogue

- Fichiers : sélecteur iOS (`.deltaskin`, `.manicskin`, `.zip`).
- Catalogue : `https://provenance-emu.com/skins/catalog.json` (même fichier sur
  GitHub), filtré par console, avec nom, auteur, vignette, nombre de
  téléchargements. Les liens qui ne mènent pas à une archive sont refusés.
- Vérifications : signature ZIP, ≤ 50 Mo, ≤ 200 Mo décompressés, ≤ 1024 entrées,
  pas de chemin absolu ni `..`, `info.json` à la racine (ou dans un seul dossier
  racine), entrées `__MACOSX` ignorées, images ≤ 8192 px, nom réservé
  `neostation-skin.json` refusé dans l'archive. Un `.zip` qui enveloppe un seul
  `.deltaskin` ou `.manicskin` est ouvert avec les mêmes limites ; un paquet de
  plusieurs skins est refusé (« importez-les un par un »). Chaque refus ou
  remarque a un message traduit.
- Téléchargement : délai d'inactivité de 30 s, fichier partiel supprimé.
- Remplacement d'un skin de même identifiant : le nouveau est installé, les
  sélections lui sont transférées, puis seulement l'ancien est supprimé ; en cas
  d'échec, l'ancien skin et ses sélections restent intacts.
- Un skin installé pour d'autres consoles que celle de la page le signale
  (« Installé pour … ») au lieu d'être marqué comme installé.
- Licences : aucun skin tiers n'est livré avec NeoStation. Les skins par défaut
  sont des dessins originaux de NeoStation. L'auteur et la source sont conservés
  et affichés.

## 4. Shaders

- Préréglages NeoStation en Metal Shading Language, portés à la main depuis
  `libretro/slang-shaders`, une passe, appliqués à chaque écran de jeu séparément
  (jamais au skin ni au menu), dans le rectangle choisi par le format d'écran.
- **Formats pris en charge : uniquement ces préréglages intégrés.** Les fichiers
  RetroArch `.slangp`, `.glslp` et `.cgp` ne sont pas chargés ; les préréglages
  multipasses (xBR, ScaleFX, crt-royale, gameboy) ne sont pas proposés.
- Préréglages : Bilinéaire net (domaine public), CRT Lottes rapide (Unlicense), CRT
  Hyllian rapide (MIT), CRT zfast (GPL-2.0+), Lignes de balayage sinusoïdales
  (domaine public), Grille LCD lcd3x (domaine public), LCD SameBoy (MIT), Matrice
  de points (domaine public), LCD zfast (GPL-2.0+).
- Mentions : l'en-tête d'origine de chaque fichier amont (auteurs, copyright,
  texte de licence) est conservé en commentaire en tête de sa source MSL dans
  `LibretroShaderLibrary.m`, avec le chemin du fichier dans
  `libretro/slang-shaders` ; la page Shaders du menu en jeu affiche une ligne de
  crédits (auteurs et licence du préréglage actif).
  `assets/legal/THIRD_PARTY_NOTICES.md` n'est pas modifié dans ce cycle : son
  contenu est figé octet par octet par un test hérité
  (`test/import_memory_candidate_scope_test.py`). La revue des licences,
  reportée par le mainteneur, suit les tests sur iPhone.
- Taille source (`SourceSize`, `OriginalSize`) : pixels de la console pour cet
  écran seulement quand l'image du cœur en est un agrandissement uniforme (les
  deux échelles à 2 % près l'une de l'autre, aucune sous 0,98 : PSP 960×544 →
  480×272, N64 640×480 → 320×240) ; sinon taille réelle de la partie en texels,
  comme RetroArch (NES 256×224 quand Nestopia rogne le surbalayage, Mega Drive
  H32 256×224, PlayStation 368×240 ou PAL 320×288, Super Game Boy de mGBA
  256×224, arcade toujours). La décision est prise à chaque image par
  `LibretroShaderSourceSize` (`LibretroGeometry.h`).
- Écarts avec l'amont, notés dans les sources MSL : toute lecture est bornée à
  la partie de l'écran (`NEO_SAMPLE`, bord répété comme `clamp_to_edge`), pour
  qu'un écran DS ou 3DS ne lise jamais l'autre ; CRT Lottes rapide rend
  pourtant noir ce qui tombe hors de l'image, comme le bord `clamp_to_border`
  noir de RetroArch sous Vulkan, Metal et GL (coins courbés noirs même avec un
  arrondi de coin à 0 ou 1), et garde `TRINITRON_CURVE` à 0 ; Bilinéaire net
  garde un préfacteur automatique d'au moins 1 ; CRT Hyllian rapide borne à 0,
  avant la puissance, les lobes négatifs de Catmull-Rom (même noir, sans NaN).
- Paramètres exposés avec curseurs, enregistrés par console ou par jeu.
- Un préréglage qui ne compile pas est refusé : le rendu standard est rétabli et
  le jeu continue.
- Mesure : temps GPU médian du présentateur affiché dans la page Shaders et écrit
  dans le journal de session ; il ne compte pas le temps GPU propre du cœur.

## 5. Format d'écran

Original/Automatique (rapport du cœur), 4:3, 16:9, 16:10, Étiré. Appliqué en
direct (dernière image redessinée pendant la pause), par console avec exception
par jeu. Le rectangle de jeu vient du skin et des zones sûres ; Étiré remplit ce
rectangle sans toucher au skin ni aux zones des boutons. Les rapports fixes
étirent l'image sans recadrage : ce n'est pas un rendu panoramique (le menu le
dit). Pour DS et 3DS, le format s'applique à chaque écran ; la disposition des
écrans est un réglage distinct.

NeoPlay et AirPlay montrent l'écran de l'iPhone (recopie système et capture
ReplayKit) : skin, format et shaders y apparaissent tels quels ; aucun changement
n'est nécessaire de leur côté.

## 6. Commandes

- Manette physique : chaque bouton de la manette peut envoyer n'importe quelle
  commande logique de la console ou une action NeoStation (menu, sauvegarde
  rapide...). Les sticks gardent leur rôle.
- Boutons tactiles : chaque bouton du skin peut envoyer une autre commande.
- Disposition : déplacer, redimensionner (glisser, pincer) ; seulement pour les
  commandes dessinées séparément (skins par défaut, éléments importés avec leur
  propre image). Les boutons peints dans l'image d'un skin ne bougent pas, et le
  menu l'explique. Une commande déplacée ne peut jamais recouvrir l'écran
  tactile (cadre et zone de toucher) ; une position impossible garde la
  dernière position valide. L'édition « pour la console » part de la
  disposition de la console, jamais de celle du jeu.
- Opacité : skins par défaut et skins importés translucides seulement ; pour
  un skin opaque le curseur est désactivé et le menu explique pourquoi.
- Bouton de menu NeoStation : placé hors de tout écran tactile et de toute
  commande affichée (règle portable `LibretroChromeLayout`, testée sur toutes
  les dispositions DS/3DS, orientations et tailles d'écran).
- Toujours conservés : multitouch, sticks, gâchettes, accès au menu (bouton
  NeoStation, ou élément `menu` du skin, ou Accueil / Options + Menu à la
  manette).
- PSP : ✕ = B, ○ = A, △ = X, □ = Y, stick = analogique gauche (entrées du cœur
  PPSSPP vérifiées dans ses sources).
- 3DS : pas de bouton HOME (L3 inverse aussi les écrans dans Azahar, ce qui
  fausserait le recadrage) ; C-stick = analogique droit.
- « Inverser les écrans » ne concerne que les skins par défaut ; avec un skin
  importé, qui place lui-même les écrans, l'action ne change rien et le dit.
- Repli Vulkan (si la copie vers Metal ne peut pas être préparée) : paysage
  seulement, un seul écran entier (tactile pour DS/3DS), sans panneau opaque ;
  shaders et écrans séparés indisponibles, annoncés dans le menu.

## 7. Orientation

`LibretroOrientation` ajoute `application:supportedInterfaceOrientationsForWindow:`
au délégué d'application : identique à l'existant hors jeu libretro, portrait et
paysage pendant un jeu libretro. `Info.plist`, `lib/main.dart` (verrouillé) et
les autres moteurs ne changent pas.

## 8. Accès dans l'application

- Réglages › Dossiers › **Consoles intégrées** (iOS) : liste des 17 consoles,
  import de jeux même sans jeu existant (cas de la 3DS), gestion des skins.
- Liste de jeux d'une console intégrée : menu d'actions › Skins.
- En jeu : menu › Affichage et commandes › Skins, Format d'écran, Disposition
  des écrans (DS/3DS), Shaders, Commandes.

## 9. Fichiers et responsabilités

| Module | Fichiers | Portable (test macOS) |
|---|---|---|
| Géométrie | `LibretroGeometry.{h,m}` | oui |
| Commandes logiques | `LibretroInputMap.{h,m}` | oui |
| Préférences | `LibretroFrontendStore.{h,m}` | oui |
| Skins | `LibretroSkin.{h,m}`, `LibretroDefaultSkins.{h,m}`, `LibretroSkinLayout.{h,m}` | oui |
| Shaders | `LibretroShaderLibrary.{h,m}` | oui (+ compilation et rendu Metal sur macOS) |
| Rendu | `LibretroMetalPresenter`, `LibretroVulkanRenderer` | non |
| Affichage skins | `LibretroSkinRenderer`, `LibretroTouchOverlay` | non |
| Session | `LibretroSession`, `LibretroSessionMenu`, `LibretroGameViewController`, `LibretroInputState`, `LibretroOrientation`, plugin | non |
| Dart | catalogue, service, `libretro_skin_service.dart`, `libretro_skin_catalog_service.dart`, écrans `lib/screens/libretro/*`, `LibretroLocale` | tests Dart |

## 10. Arbitrages après relecture de la conception

- **Options imposées avant `retro_init`** : DeSmuME lit ses options dans
  `retro_init` ; l'hôte reçoit donc valeurs par défaut, surcharges et options
  verrouillées avant `retro_set_environment` (`LibretroCoreHost.h`). Cela corrige
  aussi la surcharge sans JIT de DeSmuME, jusqu'ici ignorée. Une surcharge
  appliquée en cours de session signale une mise à jour au cœur.
- **Options verrouillées pour DS et 3DS** : DeSmuME `top/bottom`, écart `0`,
  pointeur `touch`, `desmume_pointer_mouse=enabled` ; Azahar `default`, `Top`,
  `citra_analog_function=c_stick` (sinon le C-stick déplace un curseur tactile),
  `citra_render_3d=off`. Toutes vérifiées contre les binaires épinglés par
  `test/libretro_core_options_test.py --cores`.
- **Boutons bloqués** : DS R3 (inversion d'écrans de DeSmuME), 3DS L3 et R3 (HOME,
  inversion d'écrans et clic tactile d'Azahar). Les écrans s'inversent côté
  NeoStation (action « Inverser les écrans »).
- **Manette** : la correspondance par défaut reste exactement celle d'avant pour
  chaque console ; un bouton sans commande logique transmet son identifiant
  RetroPad historique (face B du disque FDS de Nestopia sur L, micro, couvercle
  DS...). PlayStation reste en manette numérique (aucun changement de
  périphérique du cœur).
- **Portrait** : méthode d'orientation installée au chargement du pont, avant
  l'attribution du délégué d'application ; orientation déduite des dimensions de
  la vue (iPad compris, fenêtres redimensionnables d'iPadOS 26).
- **Vulkan** : anneau de deux emplacements (barrières, sémaphores et fence du
  cœur respectés), une image de latence au lieu d'un blocage à chaque image ; pas
  de surface Vulkan sur la couche visible ; repli décidé une seule fois.
- **Aperçu en direct** : les pages Format, Shaders, Disposition et Skins laissent
  le jeu visible (demi-écran, fond transparent).
- **Shaders sur l'écran tactile** : courbure et coins forcés à zéro, pour que
  l'image reste alignée avec le tactile. Taille source = pixels de la console
  seulement quand l'image du cœur en est un agrandissement uniforme (grilles
  LCD alignées quand le cœur rend en haute résolution), sinon texels réels de
  l'image, comparés à chaque image (§ 4). Temps GPU mesuré juste après le choix
  d'un préréglage.
- **Livraison** : la clé de cache de la validation Dart inclut désormais les
  sources natives lues par les tests Dart.

## 11. Vérifications prévues

- Tests de comportement macOS (hôte portable) : géométrie et formats, pointeur avec
  rotation, D-pad, stick, carte de commandes de chaque console (PSP compris),
  réaffectations, priorité jeu > console > défaut et persistance, analyse de skins
  Delta synthétiques (DS deux écrans, 3DS, PSP, portrait seul, PDF, erreurs),
  skins par défaut (17 consoles × 2 orientations × iPhone/iPad : éléments dans la
  vue, pas de chevauchement avec l'écran tactile, entrées connues).
- Shaders (`test/libretro_shader_test.py`) : compilation Metal de chaque
  préréglage et rendu de contrôle sur le périphérique Metal du runner macOS (la
  CI a affiché « Apple Paravirtual device ») : sortie finie et opaque, image
  visible, aucune fuite de l'autre moitié de la texture, chemin simple exact
  (aussi depuis une image à origine en bas), effet de la courbure, coins noirs
  de CRT Lottes rapide hors de l'image (source blanche, courbure 0,25, arrondi
  0 et 1), préfacteur de Bilinéaire net. Sans périphérique Metal, le test se
  replie sur la compilation hors ligne de chaque source MSL et l'annonce (aucun
  rendu vérifié) ; il échoue seulement si aucun compilateur Metal n'est
  disponible. La taille source des shaders (`LibretroShaderSourceSize`) est
  testée avec la géométrie (`geometry_test.m`).
- Compilation iPhone de toutes les sources du pont.
- Tests Dart : import (archives synthétiques), catalogue, clés de console,
  traductions des douze langues (clés, paramètres de substitution, chinois
  traditionnel).
- Non vérifié sans iPhone : rendu réel, rotation, tactile, performances des
  shaders, chemins GLES et Vulkan.
