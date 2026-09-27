# Correction du dispatch Haiku et des affectations automatiques

Le défaut observé dans le benchmark Jev était réel : Haiku pouvait choisir
`custom_agent` avec un profil nul. Le schéma Python l'acceptait, son repli JSON
échappait à la validation, puis Phoenix fabriquait une proposition généraliste.

## Comportement corrigé

- Chaque réponse, structurée ou JSON, est validée localement : brief non vide,
  mode cohérent, confiance explicite, agents appartenant à l'effectif, profil
  complet et archétype connu pour toute création, intégrations connues.
- Une seule tentative de correction est permise. Une réponse toujours invalide
  produit `invalid_dispatch_analysis`/HTTP 422. Phoenix relaie ce refus sans
  remplacer le profil par un agent généraliste.
- L'API fournit le catalogue réel des archétypes. Le profil DevOps conserve son
  archétype, son rôle et sa spécialisation lors de la création. Les niveaux de
  compétences restent calculés par le serveur, jamais imposés par le modèle.
- Dans New Task, `user_choice` exige une sélection explicite : aucune affectation
  ni exécution automatique d'un agent seulement partiellement adapté. Une
  proposition inexistante, peu confiante ou indisponible reste sans affectation.
- Pour les sous-missions composites, un score de correspondance nul exclut
  l'agent avant la pénalité de charge. L'absence de candidat laisse la sous-mission
  sans agent et sans exécution.

## Vérification locale

- Python : 491 tests réussis, quatre ignorés, dont 30 tests du contrat de dispatch
  et 28 du harnais d'évaluation. Ruff passe sur les fichiers Python concernés.
- Phoenix : 44 tests ciblés réussis, avec compilation normale : réponses worker,
  confirmation, choix d'agent, orchestration composite et contrôleur de dispatch.
- Web : dix tests de comportement réussis ; TypeScript passe sans erreur.
- Régressions reproduites avant correction : profil absent transformé en
  généraliste, agent sans correspondance choisi par défaut et affectation d'un
  choix partiel. Tests de réponse JSON incorrecte, référence étrangère, profil
  vide, création incomplète et refus sans mutation inclus.

Commandes :

```sh
cd apps/ai-worker
.venv/bin/python -m pytest tests evals/jev_routing/test_eval.py -q
.venv/bin/ruff check app/agents/dispatcher.py app/main.py tests/test_dispatcher.py evals/jev_routing/run_eval.py evals/jev_routing/test_eval.py
cd ../api
MIX_ENV=test mix test test/mokaid/dispatcher_worker_response_test.exs test/mokaid/dispatcher_test.exs test/mokaid/orchestrator_test.exs test/mokaid/orchestrator_research_test.exs test/mokaid_web/dispatch_controller_test.exs
cd ../web
npm run typecheck
npx vitest run src/test/new-task-dispatch.test.tsx
```

## Essais réels

Le même corpus synthétique de 72 cas EN/FR/HE et neuf répétitions a été conservé,
avec ses étiquettes inchangées. Le catalogue envoyé par l'API a été ajouté aux
entrées. Aucune tâche réelle ni aucun agent réel n'a été créé par ces appels.

Le premier essai du garde (`live/`) a accepté 74/81 réponses, toutes conformes
au routage attendu, et bloqué sept réponses. Il a révélé une confusion du modèle
entre `alternatives` (autres employés existants) et `custom_agent` (nouveau
spécialiste). Les diagnostics FR/HE ont reproduit une alternative égale à l'agent
principal, puis une alternative avec identifiant nul. Le schéma et le prompt ont
été précisés pour corriger cette confusion ; les contrôles n'ont pas été assouplis.

Le second essai complet utilise cette version finale (`live-v2/`) :

| Mesure | Résultat |
|---|---:|
| Cas principaux : choix et mode attendus | 72/72 |
| Par langue : EN, FR, HE | 24/24 chacune |
| Répétitions cohérentes avec leur cas principal | 9/9 |
| Profils complets requis dans les cas principaux | 36/36 |
| Réponses acceptées au total | 81/81 |
| Analyses nécessitant une correction, toutes récupérées | 4 |
| Appels modèle, corrections comprises | 85 |
| Temps médian / p95 des cas principaux | 4,573 s / 8,361 s |
| Coût estimé des 81 analyses, barème interne | 0,466093 USD |

Le cas Kubernetes qui révélait le défaut produit désormais un profil complet
avec l'archétype `devops` dans les trois langues. Aucun routage attendu n'a régressé
dans ce replay. Les quatre corrections montrent que le modèle peut toujours
émettre une première réponse invalide ; le garde la corrige ou la refuse.

Les mesures et empreintes exactes sont conservées dans
`verification-summary.json`. Les coûts et latences des sondes de diagnostic ne
sont pas inclus dans les métriques des replays. Les snapshots ont été comparés
aux sources exécutées et aux empreintes des manifestes.

## Portée et mise en service

Ces contrôles garantissent le respect du contrat testé, pas l'infaillibilité de
la compréhension métier. Un score de confiance n'est pas une preuve de compétence.
Le corpus reste synthétique, avec 24 familles corrélées entre langues ; il ne
remplace pas des cas clients évalués humainement. La consigne a été améliorée
après observation de ce corpus : le dernier replay est une régression sur des
cas connus, pas une mesure indépendante de généralisation.

L'indisponibilité réelle du worker conserve le repli heuristique existant. Le
chemin de production configuré en SQS n'utilise toujours pas l'analyse HTTP de
Haiku. Le choix composite reste une heuristique, influencée notamment par le
contexte parent inclus dans les briefs ; le garde de score nul n'en garantit pas
la justesse sémantique.

Modifications réalisées et vérifiées dans le workspace, sans déploiement. API et
worker doivent être livrés ensemble : l'API fournit `agent_archetypes` et le worker
exige `archetype_key` pour les créations. Un couple de versions incompatible
refuse les propositions incomplètes. Aucun basculement vers Jev n'est effectué.

Les résultats historiques de l'évaluation Jev restent intacts. Les snapshots
`dispatcher-tested.py`/`runner-used.py` correspondent au premier essai ; leurs
versions `*-v2.py` correspondent au replay final.
