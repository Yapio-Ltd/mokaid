# Mokaid — livraison cinéma et scrollytelling

La landing React/Vite conserve son hero et ses CTA. Le parcours qui suit utilise le film Higgsfield de 74 secondes, avec textes, notifications, logo et CTA en HTML. Le site est silencieux. Sur mobile, en mouvement réduit, sans JavaScript ou lorsque le film n’est pas prêt avant l’entrée, trois moments illustrés prennent le relais.

Preview locale : http://127.0.0.1:4173/ . Pour la relancer, depuis `apps/web` : `npm run preview -- --host 127.0.0.1 --port 4173`. La version compilée provient de `npm run build:seo`.

## Fichiers

- `deliveries/mokaid-web-74s.mp4` : 1920×1080, muet, sans graphismes incrustés.
- `deliveries/mokaid-social-16x9-74s.mp4` : 1920×1080, son et graphismes natifs.
- `deliveries/mokaid-social-4x5-74s.mp4` : 1080×1350, composition adaptée.
- `deliveries/mokaid-social-9x16-74s.mp4` : 1080×1920, composition adaptée.
- `deliveries/mokaid-higgsedit-editable.zip` : projets natifs, médias préparés, typographie, logo, scripts et provenance pour reprendre le montage dans Higgsedit.

Le dérivé intégré au site est `/assets/mokaid-office-journey.adac1c365481.mp4`, SHA-256 `adac1c36548182a4b68137fdba12dbe084290d6729ff75f5be6adc1a87281ff3`. Les illustrations sont également fingerprintées. Les dimensions, durées, empreintes et liens confirmés des quatre films et de l’archive sont dans `deliveries/delivery-manifest.json`.

## Code et reproduction

Le manifeste partagé est `apps/web/src/data/cinematic-story.json`. Il fixe les scènes, points scroll/temps, textes, notifications, CTA et apparition du logo. Le montage social lit ce même fichier.

Le contrôleur garde la vidéo en pause et remplace la cible en attente au lieu d’empiler les seeks. Les overlays suivent les frames présentées. Lenis et ScrollTrigger partagent le ticker GSAP existant; le stage CSS reste sticky pendant douze hauteurs d’écran de déplacement. Le chargement ne modifie jamais tardivement la hauteur d’une section déjà visible.

La recette native et ses exigences sont dans `production/README.md`. Les identifiants, paramètres, références et prompts Higgsfield sont conservés dans `production-manifest.json`, `portrait-manifest.json` et `portrait-office-manifest.json`. `framing-review.json` contient les cadrages et corrections sonores retenus.

## Validation

- TypeScript : PASS. Tests ciblés : 18/18. Lint : 0 erreur, 14 avertissements existants.
- Build et prerender : 36 routes; version HTML statique lisible sans JavaScript.
- Vrai film 1080p : PASS Chromium 151, Firefox 153, WebKit 26.5. Seeks lents/rapides/inversés, grands sauts, rattrapage de la dernière cible, médias indisponibles et latence simulée. Voir `verification/final-media-qa.md` et les rapports JSON associés.
- Mobile et mouvement réduit : aucune requête MP4. Faible débit réel 16 Kio/s : présentation statique maintenue, image décodée et CTA disponible.
- Clavier, skip, navigation répétée et retour arrière : 8 contrôles PASS. Voir `verification/keyboard-and-serving-review.md`.
- Nginx local avec la configuration de production : 200/206/304/404/416 vérifiés; plages de début et de fin correctes, cache immutable pour les assets réussis et no-store pour les erreurs.
- Encodage web : H.264, 24 images/s constantes, 1776 frames, GOP maximal 6 frames, sans B-frames, sans piste audio, index MP4 en tête.

Les tests de viewport mobile ne remplacent pas un téléphone physique. Le contrôle Safari natif au premier plan reste non certifié : lors du contrôle en arrière-plan, la nouvelle image n’a pas été présentée ; le moteur WebKit avec composition active passe la suite. Le diagnostic et le test de retour de visibilité sont documentés dans `verification/safari-visibility-investigation.md`.

La revue créative examine les plans, raccords, cadrages et graphismes par images intermédiaires. Les mesures sonores sont objectives; aucune écoute humaine n’est revendiquée. Aucune voix-off n’a été ajoutée. Les plans portrait de la pause privilégient les personnages et le baby-foot, avec le café à l’arrière-plan; le gros plan espresso reste dans le 16:9. Le travelling d’exécution a été simplifié pour conserver la géométrie du bureau.

## Budget et publication

32 générations Higgsfield, 467,5 crédits dépensés sur 933,5 autorisés ; 466 crédits restants lors de la vérification. Détail par job dans `credits-ledger.json`. Les reprises rejetées sont conservées dans la provenance.

Le code, les médias et la preview sont locaux. Aucun déploiement de production ni publication sociale n’a été effectué.
