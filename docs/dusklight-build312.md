# Build 312 — chargeur et messages Dusklight

## Constat vérifié

La capture utilisateur affiche « DusklightCore is not included in this build yet. ».
Le numéro de build installé n’est pas visible. L’IPA 311 livrée contient pourtant
`Payload/NeoStation.app/Frameworks/DusklightCore.framework/DusklightCore`, un
fichier de 41 917 104 octets, mode `0755`, SHA-256
`e7efa0a602facfaf822d5c1f7e1dab26afa9c911b1949a8b082b85be93006bb2`.
L’empreinte de cette IPA est
`71ed719d51a9f679e5c97f329dcd399ce8f3a9f9eaaa21b307d18efb6074c9ee`.

Le chargeur 311 confondait absence du fichier et échec du contrôle
`isExecutableFileAtPath`. Il refusait alors le lancement avant tout appel à
`dlopen`, avec un message affirmant que le moteur n’était pas inclus. La capture
ne suffit pas à déterminer si l’appareil utilise une ancienne IPA, si
l’installation a modifié le bundle ou si le contrôle des permissions échoue.

## Correction ciblée

- L’unique appel `dlopen` reste soumis aux vérifications normales de dyld/iOS.
  Aucun contournement de signature, téléchargement de code ou repli vers un
  émulateur n’est ajouté. Le contrôle du bit d’exécution n’est plus un verrou.
- Après un refus du chargeur, un contrôle de présence distingue fichier absent
  et image présente mais non chargeable. L’erreur native exacte, le chemin du
  moteur et le numéro de build sont conservés dans les détails techniques.
- Les messages de lancement et d’import de Dusklight sont traduits dans les
  douze langues de NeoStation. Les codes d’erreur sélectionnent le message
  utilisateur ; les diagnostics natifs ne le remplacent plus.
- `AGENTS.md` enregistre la consigne permanente des douze langues pour toute
  nouvelle interface, avec vérification des clés et des paramètres.

## Vérifications et limites

Le test natif utilise le véritable chargeur de production et une bibliothèque
sans bit d’exécution : succès attendu ; fichier invalide présent et fichier
absent : erreurs distinctes conservées. Il s’exécute sous Linux et dans la CI
macOS, sans prétendre reproduire la signature iOS de l’installation utilisateur.
Les tests Flutter vérifient les douze catalogues, toutes les erreurs natives,
les paramètres, le chinois traditionnel et l’absence de repli anglais pour les
langues prises en charge. Ces tests bloquent la construction de l’IPA.

Les quatre moteurs embarqués restent exactement ceux de la build 311, notamment
Dusklight Core `0654e3a149c4a7bf0ebd46dbd29b83b8dd10ec11`, run `35861675216`.
La limite d’une session Dusklight par ouverture de NeoStation reste inchangée.
Cette correction ne démontre pas encore que le jeu démarre sur l’iPhone du
testeur ; le numéro de build installé et un nouvel essai restent nécessaires.
