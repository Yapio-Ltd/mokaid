# Authentification et bureau 3D — validation locale

## Correction du lancement local — 16 septembre, matin

La capture utilisateur de 11:35 montrait un exécutable du 14 septembre chargé
avec les nouveaux shaders externes au bundle. Cet ancien renderer ne transmettait
pas les nouvelles lumières et n'appliquait pas le post-traitement ACES/sRGB.
Les tests graphiques et l'application complète avaient été construits dans des
répertoires différents ; le lancement local avait sélectionné l'ancien bundle.

La cible `mokaid_desktop` du répertoire `build/macos-debug` a été reconstruite,
puis l'application redémarrée. La fenêtre réelle de l'espace de travail a été
contrôlée visuellement : éclairage du sol, mobilier et personnages visibles,
glow présent et carte entièrement cadrée. Aucun paramètre du compte n'a été modifié.

## Changements livrés dans le dépôt

### Connexion, inscription et session desktop

L'inscription crée le compte et son espace de travail dans une transaction. Les sessions web sont aléatoires, révocables et transportées par cookie chiffré HttpOnly ; les écritures contrôlent l'origine et le CSRF. La déconnexion et le changement de mot de passe invalident les sessions côté serveur. Les changements de compte nettoient également les connexions temps réel et l'état des autres onglets.

Le desktop utilise le navigateur externe, un callback HTTP loopback et un code unique lié au vérificateur PKCE. Les renouvellements sont sérialisés ; une réponse perdue ne provoque plus le rejeu d'un refresh token déjà consommé. Les échecs du coffre de secrets, les annulations et les réponses tardives sont traités explicitement.

Les quotas de connexion reconnaissent le client derrière l'ALB à partir du dernier élément XFF, uniquement lorsque le pair TCP appartient aux sous-réseaux ALB explicitement configurés. Terraform conserve le mode append et la restriction du groupe de sécurité. Les préfixes falsifiés et les requêtes directes ne peuvent pas contourner les quotas.

Le [rapport auth détaillé](../apps/api/AUTH_HARDENING_2026-09-16.md) décrit les tests, la configuration et les références RFC/OWASP.

### Personnages et animations

Sept personnages retravaillés dans Blender, avec 18 actions par modèle : marche, poses de bureau, canapé, café, babyfoot et états de travail. Les fichiers `.blend` éditables et les aperçus sont dans [artifacts/avatar-quality](../artifacts/avatar-quality/).

Les tissus et la peau ont également été corrigés : six anciens exports utilisaient un métal et une émission inadaptés. Leurs textures de couleur sont conservées ; les matériaux sont désormais non métalliques et non émissifs.

Les contrôles portent sur les exports réimportés : poids et quaternions normalisés, pistes complètes, boucles continues, appuis, vitesse de marche et placement sur les sièges. Le runtime distingue la hauteur de bassin du canapé de celle des chaises. La marche suit le déplacement réel, y compris le ralentissement et les collisions. Les statuts dont l'animation est debout utilisent une pose assise lorsqu'ils occupent une chaise.

Voir les [mesures Blender et commandes de reproduction](3d-motion-validation.md).

### Lumières et présentation de la carte

Le rendu natif utilise 16 lumières issues du manifeste Blender/web, avec des lampes chaudes et des panneaux colorés. La couleur HDR et l'émission sont séparées : seuls les éléments lumineux produisent le bloom. Le filtre des textures préserve les néons et écrans tout en retirant l'émission parasite des portraits. Le résultat passe par ACES puis sRGB, avec un léger tramage pour les dégradés sombres.

Les ombres de contact simplifiées ancrent les personnages au sol. Le cadrage s'adapte à la taille de la vue ; le titre et le dock natifs disposent d'un espace réservé. Les ressources GPU restent valides pendant les redimensionnements et jusqu'à la fin des commandes en vol.

Sur le site, le halo est extrait des matériaux émissifs via GlowLayer. Les pixels blancs non émissifs ne le produisent plus. Le profil de qualité faible désactive cette passe ; le traitement ACES reste appliqué une seule fois.

## Validation et preuves

Les preuves finales et captures sont conservées dans [artifacts/validation-2026-09-16](../artifacts/validation-2026-09-16/). Les fixtures graphiques utilisent des agents synthétiques et les vrais assets ; elles ne contournent pas l'authentification du produit.

Aperçus : [carte web](../artifacts/validation-2026-09-16/web-office.png), [rendu Metal](../artifacts/validation-2026-09-16/native-office.png), [intégration desktop](../artifacts/validation-2026-09-16/native-integration/native-webengine.png), [pose canapé](../artifacts/validation-2026-09-16/web-sofa-detail.png).

| Contrôle | Résultat |
| --- | --- |
| API, sessions, OAuth et proxy de confiance | 254 tests réussis |
| Web : auth/compte/navigation et moteur 3D | 132 tests réussis |
| Application native complète | Compilation macOS réussie ; 17 suites natives réussies |
| Contacts des personnages dans le runtime natif | Semelles de −0,996 à +0,581 mm ; bassins à 0,51 m |
| Parcours Chrome auth complet | 14 contrôles réussis, aucune exception de page |
| Intégration Qt/Metal/WebEngine sur Apple M4 Pro | 16 contrôles fonctionnels réussis |
| Assets et filtres de matériaux | 6 tests réussis |
| Distribution desktop, dont les six shaders requis | 37 tests réussis |
| Shaders Windows DXC 1.9.2607 | 6 compilations strictes réussies ; réflexion des buffers vérifiée |
| Nginx et Terraform production | Configurations validées localement |

Les contrôles Metal vérifient également 12 commandes sans rétention automatique, un redimensionnement alors que des images sont en cours de calcul et la destruction du renderer avant leur achèvement. Les temps CPU d'encodage ne constituent pas une mesure de FPS.

Le probe Qt/Metal/WebEngine a réussi ses contrôles fonctionnels. Son échantillon de performances est **non qualifié**, car la fenêtre a perdu le focus pendant la mesure ; ses intervalles d'image ne sont donc pas présentés comme un benchmark. Aucun test GPU Windows n'a été effectué.

Commandes principales :

```sh
npm run typecheck --workspace=@mokaid/web
npm test --workspace=@mokaid/web -- --run src/three
npm test --prefix apps/desktop/tools/asset-cooker
MOKAID_BROWSER_CHANNEL=chrome node apps/web/scripts/verify-office-visuals.mjs
MOKAID_BROWSER_CHANNEL=chrome node apps/web/scripts/verify-office-transitions.mjs
python3 apps/desktop/scripts/check_boundaries.py
```

Les scripts Chrome exigent un serveur Vite local. Les contrôles natifs utilisent CMake/CTest avec Qt et le compilateur Metal installés. Le probe Qt/Metal/WebEngine est documenté dans [tests/graphics/README.md](../apps/desktop/tests/graphics/README.md).

## Mise en service et limites

- Appliquer la migration des sessions web et livrer l'API et le site ensemble. Les anciennes sessions web demandent une nouvelle connexion.
- Livrer également la configuration Terraform des proxys de confiance ; conserver l'API accessible uniquement depuis le groupe de sécurité ALB.
- Publier les nouveaux GLB à leurs chemins avec hash sur le CDN configuré, puis reconstruire les paquets desktop à partir du catalogue synchronisé.
- Les tests locaux ne remplacent pas une connexion Google/Cognito réelle en HTTPS ni un essai du coffre de secrets avec un compte réel.
- Les quotas Hammer restent locaux à chaque instance API ; ils ne constituent pas un plafond global partagé entre réplicas.
- Les six shaders Direct3D compilent avec DXC ; la compilation C++ et le rendu sur une machine Windows restent à vérifier.
- Le rendu natif possède des contacts au sol simplifiés ; les ombres complètes de géométrie, l'occlusion de l'environnement et toute la chorégraphie des activités web ne sont pas encore portées. Les gestes ne garantissent pas un contact exact avec chaque clavier, tasse ou barre de babyfoot.
- Aucun déploiement en production ni publication d'assets n'a été effectué.
