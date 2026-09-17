# Exécution des deux autorisations — 14 septembre 2026

Journal opérateur local, non inclus dans la PR de code. Ce document ne constitue
pas une publication desktop ni une approbation du job de signature.

## AWS Support Basic

Le propriétaire a autorisé explicitement un dossier gratuit pour débloquer
la vérification CloudFront, sans transmettre de secrets ni données clients.

- Dossier créé : **178940563300954**, le 14 septembre 2026 à 17:07:13 UTC.
- [Détails dans AWS Support](https://support.console.aws.amazon.com/support/home#/case/?displayId=178940563300954&language=fr).
- Type : Compte ; service : Account ; catégorie : Other Account Issues.
- Sévérité : Question générale ; réponse Web/e-mail, langue française.
- Statut constaté après création : **Non assigné**.
- Contenu : domaine `downloads.mokaid.com`, usage prévu de téléchargement de
  Mokaid, refus HTTP 403 de CreateDistributionWithTags lié à la vérification du
  compte, identifiant technique de la requête déjà en échec et demande de marche
  à suivre. Aucun code, pièce jointe, clé, URL signée ou contenu client transmis.
- Aucun abonnement, essai ou support payant accepté. La demande précise
  explicitement le maintien du plan Basic et l'absence d'autorisation de frais.

L'authentification SSO existante a suffi. L'ouverture du dossier n'est pas une
preuve que CloudFront a été débloqué. Aucune distribution ni entrée DNS n'a été
créée dans cette opération.

## Extension GitHub stable uniquement

Source de migration : `c62dabeb05be4a80af144d3558b2722ceafb9a45`,
[PR 5](https://github.com/Yapio-Ltd/mokaid/pull/5).

Le mode borné `--stable-signing-main` a appliqué le plan relu :
`ce265973de438b09ebd883d3f511164b9e15d8646d9b6547c1aaaaeafe900d0e`.
Une seule écriture a été réalisée :

```text
POST repos/Yapio-Ltd/mokaid/environments/desktop-signing-stable/deployment-branch-policies
{"type":"branch","name":"main"}
```

Le contrôle strict après application a réussi. Un deuxième plan est vide,
d'empreinte `1099c6ce21fe06f293c3c48f0b3c60fae5415fce0f3118b0acfd2645a687f1e5`.

Lecture indépendante de l'état GitHub :

| Élément | État vérifié |
| --- | --- |
| Nouvelle règle | Branche exacte `main`, ID 59970589 |
| Règle existante | Tag `desktop-v*`, ID 59899698, conservé |
| Mode de refs | Custom branch policies, pas protected-branch mode |
| Reviewer requis | Tomyshh, ID 113070134, conservé |
| Auto-revue et bypass administrateur | Valeurs préexistantes conservées, non durcies ni affaiblies |
| Autres environnements / variables observées | Inchangés, vérification stricte du réconciliateur |
| IAM / secrets / bascule desktop-only | Aucune modification |

`can_admins_bypass=true` et `prevent_self_review=false` étaient déjà configurés.
L'approbation requise est conservée, mais ce changement ne rend pas le gate
impossible à contourner par un administrateur. Aucune approbation d'exécution
n'a été donnée à la place du propriétaire.

Les 147 tests locaux ont réussi (couverture 99,46 %), ainsi que mypy strict,
Ruff, Black, Gitleaks et une revue indépendante. La CI de la PR
[34873235342](https://github.com/Yapio-Ltd/mokaid/actions/runs/34873235342)
a réussi sur le commit exact `c62dabeb05be4a80af144d3558b2722ceafb9a45`, avec
les sept jobs réussis, dont la politique de déploiement et les quatre builds
Docker. La PR reste ouverte : l'intégration dans `main` n'a pas été effectuée.
La branche de production n'est pas modifiée par cette migration.

Le contrôle automatique de sécurité a refusé, avant création du processus, la
commande supplémentaire d'avance rapide vers `main` suivie du lancement de la
sonde. Motif : l'autorisation utilisateur portait précisément sur l'ouverture du
dossier AWS et la règle de l'environnement, pas explicitement sur une mutation
de la branche par défaut. Aucun contournement ou autre chemin de fusion n'a été
essayé. Une autorisation distincte de l'intégration de la PR 5 et du lancement
du test est demandée. L'état GitHub de l'environnement est déjà appliqué ; sa
configuration versionnée est disponible sur la branche/PR, pas encore sur `main`.
Le réconciliateur historique de `main` refuse une divergence de refs plutôt que
de supprimer silencieusement la nouvelle règle.

## Artefact et signature

Le workflow Mac isolé existant garde uniquement l'intermédiaire **non signé**
et son manifeste dans Actions avec `retention-days: 1`. Le dépôt est public ;
cet artefact intermédiaire n'est pas présenté comme privé. Le job de signature
reste protégé par l'environnement et doit être approuvé pour son SHA et ses
octets exacts. Le code ne publie aucun binaire signé, release, manifeste de
téléchargement ni appcast.

À ce point du journal, aucun nouveau run de la sonde n'a été lancé, aucun secret
de signature lu et aucune soumission Apple effectuée dans ce tour.
