# NeoPlay Windows 0.8.0 — rendu 2K/4K avec priorité à la fluidité

La version 0.8.0 du récepteur Windows ajoute un réglage « Résolution de rendu », indépendant de « Netteté » :

- Automatique : sélection en fonction de la fenêtre (par défaut).
- Native : conservation des pixels de la capture.
- 2K / QHD : rendu interne jusqu'à 2560 × 1440.
- 4K / UHD : rendu interne jusqu'à 3840 × 2160.

Les réglages 2K/4K ne modifient **pas** la capture ReplayKit ou le flux H.264 transmis par l'iPhone : le récepteur effectue le rendu/agrandissement localement via son WebGL2 existant. La taille affichée respecte le ratio natif de la source ; une capture 2868 × 1320 peut donc produire un rendu UHD 3840 × 1768. Une dalle physique 2K ne peut pas afficher 4K pixels distincts, mais elle peut réduire un rendu calculé en UHD. Le rendu n'invente pas de détails absents de la source.

Le sélecteur de netteté **Original / Améliorée / Renforcée** continue de fonctionner en parallèle. En cas de pertes d'images importantes (> 7 % pendant une période de 3 s) ou de soumission du rendu GPU trop coûteuse (> 13 ms), NeoPlay réduit automatiquement la résolution interne **UHD → QHD → Native**, puis la rétablit par paliers après 20 s stables. Ce mécanisme ne redémarre pas l'audio, ne touche pas à l'horloge vidéo et ne demande pas de diminution du débit réseau ; la régulation existante du lien demeure indépendante. Si WebGL ne fonctionne pas, le canvas 2D affiche la source d'origine.

L'interface affiche séparément la résolution de la capture reçue et les dimensions du rendu ; elle indique si une réduction de rendu intervient. Choix conservés au redémarrage et libellés complets dans les 12 langues NeoStation. Les essais doivent distinguer **qualité visuelle 2K/4K**, **cadence mesurée** et **latence réelle** sur l'iPhone/PC.

Compilation Windows reproductible, depuis `tools/neoplay-receiver` :

```powershell
npm ci --ignore-scripts
npm test
node node_modules/electron/install.js
npm run build:windows
npm run build:installer
```

Sortie attendue : `tools/neoplay-receiver/dist/NeoPlay-Setup-0.8.0.exe`. GitHub Actions `neoplay-exe.yml` lance les tests, le smoke test Electron intégré et la création de l'installateur sur Windows. Aucune modification de l'IPA iOS, du pipeline ReplayKit, de RPCS3 ni de NeoSwap.
