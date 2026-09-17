# Personnages atypiques — 17 septembre 2026

Trois personnages créés dans Blender 5.2.0 LTS, exportés et réimportés pour validation.

| Personnage | Direction visuelle | Source éditable |
| --- | --- | --- |
| Byte | Robot rétro, tête écran, céramique ivoire, corail et bleu pétrole | `avatar_byte.blend` |
| Nyx | Hackeuse cyberpunk, coiffure asymétrique violette, veste et accents cyan | `avatar_nyx.blend` |
| Moss | Esprit botanique, couronne végétale, oreilles pointues, tenue ambre et vert mousse | `avatar_moss.blend` |

`atypical-collection.blend` réunit les trois personnages avec leurs rigs et une scène de présentation. `characters-gallery.png` montre les modèles réellement réimportés depuis les GLB finaux. Les images `characters-typing.png`, `characters-walking.png` et `characters-carrying_coffee.png` montrent des poses issues de leurs animations. `office-new-characters.png` est un rendu du moteur Metal de l'application avec neuf personnages de démonstration et la caméra légèrement rapprochée ; le canapé gauche reste entier.

## Rig et animations

Chaque personnage possède un squelette de 33 os, une peau pondérée et 48 animations squelettiques éditables : repos, marche et variantes, travail, frappe, réflexion, téléphone, café, conversations, baby-foot, assise sur chaise/canapé et transitions. Les modèles, silhouettes, vêtements et matériaux sont nouveaux. Le squelette, les mains articulées, les surfaces de contact des chaussures et les mouvements calibrés proviennent du GLB `avatar_design.1c0dba698d81.glb` utilisé par l'application. Les animations ont ainsi les mêmes conventions de contact et de nommage que les autres agents. Il n'y a pas de rig facial séparé.

La liste exacte des clips, les empreintes SHA-256 et les chemins de livraison sont dans `../../assets/avatar-atypical.json`. Le rapport `validation.json` contrôle les fichiers exportés, notamment les 48 clips, la normalisation des poids, les boucles, les transitions, l'appui des pieds et la tenue du téléphone et de la tasse.

## Stockage et intégration

Les GLB de production sont stockés sous un nom contenant leur empreinte dans `../../assets/optimized/` et `../../apps/web/public/assets3d/`. Les portraits sont enregistrés dans les dossiers de portraits natifs et web, avec leur provenance. Les catalogues API et web, le moteur natif, le préparateur d'assets et les règles de packaging reconnaissent les trois nouveaux avatars.

L'intégration est locale. Aucun déploiement, envoi S3, modification de la base distante ou remplacement d'un agent existant n'a été effectué. Le binaire macOS et les ressources natives ont été reconstruits ; le nouveau cadrage sera utilisé au prochain lancement de ce binaire.

## Reproduire

Depuis la racine du dépôt, avec Blender installé :

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/blender-atypical-avatars.py
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/validate-avatar-life.py -- artifacts/avatar-atypical
python3 scripts/register-atypical-avatars.py
node apps/desktop/tools/asset-cooker/cook.mjs apps/desktop/build/assets
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/blender-atypical-gallery.py
```

Le script d'enregistrement vérifie les empreintes et les rapports avant de modifier les catalogues. Les anciennes révisions ne sont pas supprimées. Pour retoucher un personnage sans recréer le trio, le script Blender accepte `-- --only byte`, `nyx` ou `moss`.

## Vérifications effectuées

- Réimportation Blender : 48 animations et contacts validés pour chacun des trois GLB.
- Préparateur natif : 12 tests réussis ; les trois modèles sont préparés avec les assets existants.
- Web : 15 tests de portraits réussis et vérification TypeScript réussie.
- Packaging : 37 tests réussis, dont les fixtures contenant les trois nouveaux assets.
- C++ : moteur, assets réels, conversations et pages QML vérifiés ; nouveaux portraits inclus.
- Compilation macOS et exécution du moteur sous UndefinedBehaviorSanitizer réussies.
- Rendu Metal réel : neuf agents, animations, redimensionnement et destruction du moteur validés.
