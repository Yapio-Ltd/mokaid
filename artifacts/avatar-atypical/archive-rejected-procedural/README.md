# Trois personnages humains — 17 septembre 2026

Les trois anciens personnages fantastiques ont été refaits en humains aux vêtements du quotidien. La direction reste une 3D stylisée adaptée au bureau Mokaid ; il ne s’agit pas de scans photoréalistes.

| Personnage | Look | Identifiant conservé | Source Blender |
| --- | --- | --- | --- |
| Hugo | Architecte : veste marine, henley écru, pantalon ajusté, lunettes et barbe poivre et sel | `avatar_byte` | `avatar_byte.blend` |
| Inès | Créative : carré châtain, chemise écrue, foulard brique, pantalon anthracite et petites boucles d’oreilles | `avatar_nyx` | `avatar_nyx.blend` |
| Malik | Artisan : boucles naturelles, surchemise olive, tablier indigo avec poche à crayon, pantalon tabac | `avatar_moss` | `avatar_moss.blend` |

Les identifiants techniques restent stables pour remplacer les trois modèles dans les catalogues. Les anciens modèles et la première galerie sont conservés dans `archive-fantasy/` et dans les anciennes révisions GLB contenant leur empreinte.

## Modélisation

Nouveaux visages avec paupières, nez, lèvres, oreilles et sourcils ; coiffures naturelles ; nouveaux bras et jambes avec maillage continu aux articulations ; mains avec doigts séparés et ongles ; chaussures fermées avec semelles et lacets. Les vêtements comportent des cols, revers, boutons cousus, poches, ceintures, coutures et accessoires adaptés à chaque look.

Les détails sont de la vraie géométrie skinnée exportée dans les GLB. Les images montrent les modèles Blender et les GLB réimportés, sans retouche générative.

## Rig et animations

Chaque personnage conserve le squelette de 33 os et les 48 animations squelettiques éditables : repos, marche et variantes, travail, frappe, réflexion, téléphone, café, conversations, baby-foot, assise sur chaise/canapé et transitions. Le squelette et les clips proviennent du GLB `avatar_design.1c0dba698d81.glb` utilisé par l’application. La nouvelle géométrie est pondérée sur ce squelette et conserve sa hauteur de référence et ses points d’interaction. Il n’y a pas de rig facial séparé.

Les noms des clips, les empreintes SHA-256 et les chemins de livraison sont dans `../../assets/avatar-atypical.json`. `validation.json` porte sur la réimportation des GLB exportés et contrôle les poids, les boucles, les transitions, les pieds et les accessoires.

## Fichiers

- `atypical-collection.blend` : les trois rigs éditables réunis dans une scène de présentation.
- `characters-gallery.png` : galerie des GLB finaux réimportés.
- `characters-typing.png`, `characters-walking.png`, `characters-carrying_coffee.png` : poses réellement issues des animations.
- `portrait-byte.png`, `portrait-nyx.png`, `portrait-moss.png` : portraits destinés aux interfaces.
- `office-new-characters.png` : rendu de contrôle du moteur natif avec les nouveaux modèles.

Les GLB contenant leur empreinte sont copiés dans `../../assets/optimized/` et `../../apps/web/public/assets3d/`. Les portraits et leur provenance sont mis à jour côté natif et web. L’intégration est locale ; aucun agent existant ni aucune base distante n’a été modifié.

## Reproduire

Depuis la racine du dépôt :

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/blender-atypical-avatars.py
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/validate-avatar-life.py -- artifacts/avatar-atypical
python3 scripts/register-atypical-avatars.py
node apps/desktop/tools/asset-cooker/cook.mjs apps/desktop/build/assets
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/blender-atypical-gallery.py
```

Le script d’enregistrement vérifie les empreintes et les rapports avant de modifier les catalogues. Pour retoucher un seul modèle, le script Blender accepte `-- --only byte`, `nyx` ou `moss`.

## Validation de cette révision humaine

- Blender : 33 os et 48 clips par personnage ; poids, boucles, transitions, téléphone, café et appuis au sol validés sur les GLB réimportés.
- Contacts assis : écart maximal des semelles inférieur à 0,5 mm ; tenue du téléphone inférieure à 0,06 mm.
- Catalogue natif : 4 tests réussis ; modèles préparés et empreintes des copies de livraison vérifiées.
- Web : 15 tests de portraits réussis et vérification TypeScript réussie.
- Natif : compilation macOS, tests du moteur, assets réels et pages QML réussis.
- Metal sur Apple M4 Pro : neuf agents rendus, redimensionnement et destruction validés ; moyenne GPU de 2,64 ms sur les six images de mesure du test. Cette mesure courte ne représente pas un benchmark de toutes les machines.
