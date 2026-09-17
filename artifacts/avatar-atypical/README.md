# Personnages fondés sur les modèles Mokaid existants

Cette révision remplace les personnages procéduraux rejetés par trois variantes de garde-robe des personnages déjà utilisés dans Mokaid. Le corps, le visage, les cheveux et leurs proportions restent ceux du modèle source. Les changements portent sur les couleurs des vêtements dans les textures existantes ; les détails et ombrages de ces textures sont conservés.

| Personnage | Modèle source | Identifiant conservé | Garde-robe |
| --- | --- | --- | --- |
| Hugo | `avatar_corporate` | `avatar_byte` | Chemise bleu pétrole à manches retroussées, pantalon anthracite, montre existante |
| Inès | `avatar_finance` | `avatar_nyx` | Veste terracotta, chemisier ivoire, pantalon anthracite, lunettes et chignon existants |
| Malik | `avatar_developer` | `avatar_moss` | Sweat vert forêt, jean indigo, baskets, barbe et lunettes existantes |

Ces personnages reprennent le style 3D des agents existants. Ils ne sont ni de nouvelles sculptures anatomiques ni des scans photoréalistes.

## Géométrie, rig et animations

Chaque variante conserve intégralement la géométrie, les UV, les nœuds, les skins et les animations de son GLB source : 33 articulations et 48 clips, avec leurs durées et les interactions café/téléphone d’origine. Aucune nouvelle mise à l’échelle du corps, modification des os ou pondération n’est appliquée aux GLB livrés.

Le bloc binaire BIN original est conservé comme préfixe exact du nouveau BIN ; les nouvelles données de texture sont ajoutées à sa suite. Le script d’enregistrement vérifie cette égalité avant de mettre à jour les catalogues. `report.json` contient le chemin `source_asset`, l’empreinte du fichier source `source_sha256`, celle du BIN original `geometry_buffer_sha256`, le `donor_slug` et les indicateurs de préservation. `../../assets/avatar-atypical.json` reprend ces informations lors de l’enregistrement.

## Fichiers et aperçus

- `avatar_byte.glb`, `avatar_nyx.glb`, `avatar_moss.glb` : variantes destinées à la livraison.
- `avatar_byte.blend`, `avatar_nyx.blend`, `avatar_moss.blend` : sources Blender éditables issues de ces GLB, avec leur rig, leurs animations et leur nouvelle texture.
- `atypical-collection.blend` : les trois personnages réunis dans une scène de présentation.
- `characters-gallery.png` : aperçu des GLB réimportés, sous un éclairage neutre.
- `proportions-reference.png` : chaque variante placée à côté de son modèle source, à la même hauteur de présentation de 1,75 m.
- `gallery-measurements.json` : limites et dimensions des corps évalués au repos, hors accessoires, et facteurs uniformes de présentation. Seul le parent de présentation est transformé ; les proportions et les rigs restent intacts.
- `characters-typing.png`, `characters-walking.png`, `characters-carrying_coffee.png` : poses issues des clips conservés.
- `portrait-byte.png`, `portrait-nyx.png`, `portrait-moss.png` : portraits pour les interfaces ; `*-wardrobe.png` : textures de vêtements modifiées.
- `office-new-characters.png` : aperçu de contrôle produit par le moteur natif.

Après enregistrement, les GLB nommés avec leur empreinte sont copiés dans `../../assets/optimized/` et `../../apps/web/public/assets3d/`, avec mise à jour des portraits et de leur provenance. Les identifiants des trois variantes restent stables.

`archive-rejected-procedural/` conserve les sources, la galerie et les rapports de la version humaine procédurale rejetée. `archive-fantasy/` contient la première version fantastique. Ces archives ne décrivent pas les modèles de cette révision.

## Reproduire

Depuis la racine du dépôt :

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/blender-atypical-avatars.py
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/validate-avatar-life.py -- artifacts/avatar-atypical
/Applications/Blender.app/Contents/MacOS/Blender --background --python scripts/blender-atypical-gallery.py
python3 scripts/register-atypical-avatars.py
node apps/desktop/tools/asset-cooker/cook.mjs apps/desktop/build/assets
```

Le script Blender accepte `-- --only byte`, `nyx` ou `moss` pour traiter une variante.

## Vérification

Le validateur réimporte les GLB et contrôle les 48 clips, les poids, les boucles, les transitions, les pieds au sol et les interactions avec le téléphone et la tasse. Il écrit les résultats et les empreintes des fichiers contrôlés dans `validation.json`.

Le registre exige des empreintes concordantes entre GLB, rapport d’auteur et rapport de validation. Il vérifie aussi le fichier source, l’empreinte de son BIN et la conservation de ce BIN comme préfixe de la variante. La galerie permet de comparer visuellement les silhouettes aux originaux ; ses mesures donnent les dimensions évaluées de chaque paire.

Contrôles exécutés sur cette révision :

- Réimport Blender : 48 clips validés pour chacun des trois personnages ; poids, contacts, boucles et transitions conformes.
- Conservation : géométrie, nœuds, skins, animations et accessors identiques aux donneurs ; BIN source conservé octet pour octet. Les mesures des corps original/variante sont exactement égales.
- Catalogues : les empreintes des GLB enregistrés correspondent au rapport d’auteur et au rapport de validation ; 4 tests de politique des sources passent.
- Portraits web : 15 tests passent ; vérification TypeScript et format du catalogue API réussis.
- Application native recompilée ; tests `desktop.engine`, `desktop.real_assets` et `desktop-native-pages-qml` réussis.
- Rendu Metal sur Apple M4 Pro : bureau avec les trois variantes et six personnages existants, 12 frames avec vérification des ressources GPU réussies. Résultat dans `office-new-characters.png`.

Les versions précédentes restent archivées. Cette révision est enregistrée dans les catalogues locaux ; elle ne modifie pas les agents affectés dans une base distante.
