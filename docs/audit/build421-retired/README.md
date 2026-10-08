# Sources et contrôles retirés à la demande du mainteneur

Ces fichiers texte conservent les travaux de l'audit Build 421 pour comparaison.
Ils ne sont ni des sources applicatives ni des tests du parcours désormais
retenu. Le mainteneur a demandé le retour au parcours Build 419 et l'abandon
des réparations le 8 octobre 2026.

La vérification active est décrite dans
`docs/retroarch-rollback-2026-10-08.md` : cache d'export sans écritures de lignes
virtuelles, scanner antérieur, transport direct et diagnostics. Le contrôle des
transactions concurrentes spécifiques à la restauration est retiré en même
temps que cette restauration et sa modification de l'adaptateur SQLite.
