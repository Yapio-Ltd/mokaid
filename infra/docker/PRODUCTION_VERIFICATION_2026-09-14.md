# Vérification du déploiement de production — 14 septembre 2026

## Résultat vérifié

Le commit `d6f8eba891eef26ba6589ede3ab6c3c886e71815` a été déployé par le
[workflow automatique 34844132115](https://github.com/Yapio-Ltd/mokaid/actions/runs/34844132115).
Le job réel `Deploy (prod)` est terminé avec succès, et non ignoré.

La chaîne de promotion a conservé exactement ce commit, sans push forcé ni
déclenchement manuel ou relance du déploiement :

1. [CI de la PR nº 3](https://github.com/Yapio-Ltd/mokaid/actions/runs/34841943478) réussie.
2. Avance rapide de `main`, puis [CI push/main](https://github.com/Yapio-Ltd/mokaid/actions/runs/34842721957) réussie.
3. Avance rapide de `prod`, puis [CI push/prod](https://github.com/Yapio-Ltd/mokaid/actions/runs/34843483790) réussie.
4. Déploiement automatique `workflow_run` après vérification du commit et de la CI.

Chaque étape suivante est individuellement confirmée réussie : quatre builds et
publications ECR, quatre scans ARM64, staging isolé des mêmes images, renouvellement
OIDC, quatre préparations de révisions, migration de base de données, quatre
déploiements et contrôle HTTP public depuis GitHub. Le retour arrière n'a pas été
déclenché ; son étape de récupération a été ignorée normalement après succès.

## État réel des services

Lecture indépendante finale à **12:56:30 UTC**, dans `mokaid-prod` :

| Service | Ancienne révision | Révision exécutée | Déploiement | Tâches souhaitées / actives / en attente |
| --- | --- | --- | --- | --- |
| API | 43 | 44 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |
| Worker IA | 38 | 39 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |
| Web | 44 | 45 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |
| CRM | 4 | 5 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |

Les quatre services ont `deploymentCircuitBreaker.enable=true` et `rollback=true`.
Les autres réglages de déploiement ont été conservés, notamment minimum 100 % et
maximum 200 %. Aucun rollback ni déploiement `FAILED` n'a été observé.

Les définitions et les tâches RUNNING utilisent les URI et digests exacts suivants.
ECS expose ici le digest de l'index OCI, pas celui du manifeste ARM64 enfant.
Chaque index a aussi été résolu indépendamment vers un unique manifeste Linux ARM64.

| Dépôt ECR | Digest de l'index OCI vérifié |
| --- | --- |
| mokaid-api | `sha256:a66fb4d08b64f31b388cf387ca11e62b45aa4d6c517d6dc26dfb88ca86858086` |
| mokaid-ai-worker | `sha256:3ec27b9af4218f19d3131d0b9b4e2fcdc9b6ea05f2561c7c00345ed4c530063f` |
| mokaid-web | `sha256:53a2209b3cc8605383e712d44487112f9777d3ac58bc8376577a1b7caa4ccc1b` |
| mokaid-crm | `sha256:98d7971148b01491322de2cc63b882c48c7e0de4a7711932842e33cb28e41a8f` |

Attention : `healthStatus` ECS des tâches et conteneurs est `UNKNOWN`, pas
`HEALTHY`. La convergence ECS et les sondes HTTP réussies ne transforment pas
ce champ en une preuve de santé de chaque fonction métier.

Contrôle distinct du répartiteur ALB à **12:58:33 UTC** : API, web et CRM ont
chacun une cible `healthy`, sans cible `draining` ni `unhealthy`. Le worker n'a
pas de target group : aucune santé ALB ne peut être affirmée pour ce service.

## Contrôles publics et configuration

Le même script [verify-production.mjs](../../.github/scripts/verify-production.mjs)
a réussi depuis la connexion locale puis depuis GitHub :

- HTML prérendu, H1 et URL canonique pour accueil, tarifs et téléchargement.
- Sitemap présent, comprenant le téléchargement et excluant les routes privées.
- Pages compte, connexion et autorisation desktop : `noindex` et `no-store`.
- Route inconnue : 404 ; santé API : 200.
- Utilisateur anonyme : `/api/me` et requête d'autorisation desktop refusés en 401.

La règle WAF autorisée ouvre uniquement l'hôte exact `mokaid.com` à l'international,
y compris ses routes API. Le filtrage géographique des autres hôtes, dont
`crm.mokaid.com`, n'a pas été ouvert globalement. Les droits applicatifs restent
indépendants du WAF. Aucun changement DNS supplémentaire n'était nécessaire.

Trois réglages ont été revérifiés sans afficher leurs valeurs sensibles éventuelles :
mode d'authentification existant conservé, URL web desktop inchangée et bascule
desktop-only désactivée. L'expérience web reste donc accessible à ce stade : elle
ne doit pas être coupée avant disponibilité des installateurs signés et parité
fonctionnelle du desktop. Ce résultat n'est pas encore la livraison desktop-only.

## Correctifs et limites de validation

Deux échecs précédents ont été corrigés sans neutraliser les protections :

- Trivy sélectionnait AMD64 dans un index exclusivement ARM64 : plateforme fixée
  explicitement pour les quatre scans, mêmes versions et critères de blocage.
- ECS refusait `tags: []` : champ omis pour les révisions sans tags, tags non vides
  conservés intégralement, réponses malformées rejetées sans exposer leurs valeurs.

Le correctif de tags passe 85 tests de scripts, 106 tests de politique, mypy strict,
Ruff ciblé, contrôle de diff et Gitleaks. Il a été relu indépendamment, puis confirmé
par l'enregistrement réel des révisions dans le déploiement réussi.

La migration ajoutée crée les tables de sessions desktop ; aucune ancienne migration
n'a été modifiée ou supprimée. La comparaison a été faite depuis le commit du tag
API réellement déployé précédemment, `bd7a0cf`, vers le commit cible. Aucun rollback
automatique de base de données n'est exécuté par la chaîne.

Les scans bloquent les vulnérabilités HIGH/CRITICAL avec correctif disponible.
Ils ne prouvent pas l'absence de vulnérabilités non corrigées ou de moindre gravité.
Les audits Hex et npm restent nécessaires en plus des scans d'images ; voir le
[rapport de sécurité](SECURITY_VALIDATION.md). Aucun contenu client ni secret n'a
été consulté pour les contrôles de métriques et d'état décrits ici.

## Premières mesures après stabilisation

Métriques AWS/ECS du service, pas une dimension par révision. Les révisions ont
été contrôlées avant et après la collecte. Les fenêtres débutent après la première
observation COMPLETED, avec des points disponibles jusqu'à 12:54 UTC.

| Service | Fenêtre UTC | Points par série | CPU moyenne / maximum | Mémoire moyenne / maximum |
| --- | --- | --- | --- | --- |
| API | 12:43–12:56 | 12 | 1,96 / 3,53 % | 24,80 / 28,91 % |
| Worker | 12:48–12:56 | 7 | 0,59 / 1,18 % | 21,09 / 21,09 % |
| Web | 12:51–12:56 | 4 | 0,04 / 0,11 % | 0,59 / 0,59 % |
| CRM | 12:54–12:56 | 1 | 0,10 / 0,32 % | 10,16 / 11,91 % |

Ces fenêtres courtes et différentes ne permettent pas de conclure à une amélioration
face à la référence d'une heure relevée avant déploiement. Aucun point manquant
n'est assimilé à zéro. Ce n'est ni un test de charge ni une qualification GPU.

## Livraison encore incomplète

- CloudFront refuse la création du CDN de téléchargements dans l'attente d'une
  vérification du compte AWS. Autorisation d'ouverture d'un dossier Support demandée,
  sans réponse reçue à la rédaction. Aucun dossier prétendument ouvert.
- Service de signature Windows non configuré. Aucun installateur public non signé
  ne doit contourner ce prérequis.
- Les éléments de signature Mac sont raccordés au coffre dédié, mais un vrai
  installateur public signé/notarisé et une mise à jour signée restent à valider.
- Pas encore de binaire public, d'appcast actif ni de CDN `downloads.mokaid.com`
  opérationnel. Les canaux de mise à jour ne doivent pas être promus à vide.
- Parité fonctionnelle desktop à terminer, tests physiques M1/Iris Xe/NVIDIA et
  tests d'installation/mise à jour sur machines propres toujours requis.

Le succès de ce déploiement ne valide pas tous les parcours authentifiés, les
intégrations fournisseurs, une restauration de base de données, une panne réelle
avec rollback, la performance native 3D ou la distribution publique desktop.
