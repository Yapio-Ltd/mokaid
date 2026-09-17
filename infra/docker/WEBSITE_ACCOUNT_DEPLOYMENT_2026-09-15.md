# Site vitrine et espace compte — livraison du 15 septembre 2026

## Résultat

Le site public `https://mokaid.com` sert désormais la landing, le téléchargement
et l'espace compte. Les anciennes routes Office redirigent vers `/download`.
La landing reste accessible lorsqu'une session est enregistrée.

- Commit : `d44e539e7b9232d25d5c6057a7352ee6cb0bf3be`.
- PR intégrée : https://github.com/Yapio-Ltd/mokaid/pull/6
- CI PR réussie : https://github.com/Yapio-Ltd/mokaid/actions/runs/34934169668
- CI main réussie : https://github.com/Yapio-Ltd/mokaid/actions/runs/34935014923
- CI prod réussie : https://github.com/Yapio-Ltd/mokaid/actions/runs/34935019646
- Déploiement et job réel `Deploy (prod)` réussis :
  https://github.com/Yapio-Ltd/mokaid/actions/runs/34935807052

Après la CI PR, main puis prod ont été avancés sans force au même commit ; leurs
CI ont tourné en parallèle. Le déploiement automatique a attendu la CI prod.
Aucune protection ni condition de contrôle de la CI prod n'a été désactivée.

## Cause et correction

La variable de production `MOKAID_DESKTOP_ONLY=false` maintenait l'ancienne
application web tant que les installateurs signés n'étaient pas disponibles.
Le site n'est désormais plus commandé par cette attente : la compilation web
est toujours limitée au marketing et au compte. Le contrôle serveur des clients
métier conserve sa bascule et sa vérification de disponibilité des installateurs.

Les liens téléchargement et connexion/compte sont visibles dès le premier écran,
sur ordinateur et mobile. La copie du hero explique le logiciel desktop et
l'espace compte web. Le hero reste visible en mode mouvements réduits.

## Vérifications

- TypeScript, ESLint ciblé, 157 tests web, cinq tests SEO et deux tests de
  disponibilité des installateurs : réussis.
- 36 pages publiques prérendues, sitemap contrôlé.
- Huit parcours Chromium locaux avec données fictives : accueil anonyme/avec
  session aux formats desktop/mobile, compte, facturation, plans, usage,
  dépenses, export de facture, connexion et consentement desktop.
- Revue visuelle et correction de contraste du CTA final effectuées.
- Après livraison, script public `verify-production.mjs` réussi : HTML, marqueur
  `marketing-account`, liens, canonicals, sitemap, pages privées, 404 et API.
- Chromium contre le vrai domaine : accueil anonyme et session synthétique,
  anciennes routes `/dashboard`, `/agents/new`, `/tasks`, `/projects`,
  `/integrations` redirigées vers `/download`. Aucun moteur 3D, WebSocket Office,
  canvas ou appel API métier chargé. Aucun compte client réel consulté.

Preuves locales : `/private/tmp/mokaid-live-web-boundary/results.json` et captures
voisines ; contrôles locaux : `/private/tmp/mokaid-landing-account-review/`.
Checkout du correctif : `/private/tmp/mokaid-web-landing-account` (propre).
Dernière vérification de résultat : 15 septembre 2026, 06:42 UTC.

La lecture ECS directe depuis le profil AWS local était indisponible (SSO
expiré). Le résultat de déploiement provient du workflow AWS réussi et le résultat
web est confirmé séparément sur le domaine public ; aucune lecture ECS locale
réussie n'est prétendue. Le premier lancement du contrôle public indépendant a
rencontré un délai du contrôle automatique d'autorisation ; sa relance a réussi.

## Limite restante : distribution desktop

Aucun installateur public n'a été publié par cette correction. Lors du diagnostic,
`downloads.mokaid.com` ne résolvait pas et la liste des releases GitHub était vide.
La page de téléchargement conserve sa validation du manifeste stable et ne
présente pas de liens d'installateurs fictifs. La publication des installateurs
reste une livraison distincte non achevée.
