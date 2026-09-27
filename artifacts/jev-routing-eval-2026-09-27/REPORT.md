# Décision : conserver le dispatcher actuel, ne pas activer Jev

Évaluation réalisée le 27 septembre 2026, heure de Jérusalem. Le besoin était de
choisir les bons agents et de déterminer quand proposer un nouveau spécialiste.

**Décision finale : conserver Haiku pour le chemin de sélection qui appelle le
LLM. Ne pas intégrer la passerelle Jev fournie dans le chemin critique de Mokaid
sur la base de cet essai.** Le bénéfice de précision n'est pas établi et l'accès
testé ne permet pas de mener la comparaison complète sans échecs de service.
Ce constat porte sur `www.jevai.org` avec l'accès fourni, pas sur la qualité
intrinsèque du modèle Jev ni sur la disponibilité de l'API directe TypeSafe.

## Ce qui a réellement été exécuté

- Corpus fictif fixé avant les résultats : 72 entrées, soit 24 scénarios traduits
  en anglais, français et hébreu. Les métadonnées d'agents restent identiques.
- 36 choix d'agents existants, 18 spécialités absentes, 12 compétences partielles
  avec choix utilisateur et six demandes vagues. Neuf variantes contiennent des
  instructions parasites dans les métadonnées ou noms de fichiers.
- Neuf répétitions supplémentaires programmées par fournisseur, avec ordre
  mélangé de façon reproductible. Aucun seuil ajusté après lecture des résultats.
- Baseline : véritable `dispatcher.analyze`, prompt, schéma, modèle configuré
  `claude-haiku-4-5`, limite de tokens et repli JSON existants. Pas de modèle simulé.
- Jev : endpoint natif de la passerelle communautaire, choix du mode, choix du
  candidat et adéquation absolue de chaque agent. Seuil exploratoire fixé à 0,5.
- Vérification séparée des décisions brutes et du filtre de routage Phoenix
  reproduit en Python. Les tâches et agents ne sont jamais réellement créés.
- Aucune donnée de locataire, aucun fichier utilisateur et aucune clé dans les
  prompts. La clé Jev a été lue en mémoire depuis AWS Secrets Manager.

## Résultats

| Mesure | Haiku actuel | Jev, passerelle fournie |
|---|---:|---:|
| Entrées principales prévues | 72 | 72 |
| Entrées principales tentées | 72 | 6 |
| Réponses principales exploitables | 72 | 1 |
| Décisions conformes parmi ces réponses | 72/72 | 1/1, effectif insuffisant |
| Entrées principales non tentées | 0 | 66 |
| Répétitions terminées avec réponse | 9 | 2, sans paire principale disponible |
| Total entrées tentées, répétitions comprises | 81 | 8 |
| Total réponses exploitables | 81 | 3 |
| Total entrées en échec après la politique de reprise | 0 | 5 |

### Haiku

Les 24 cas de chaque langue donnent le mode et l'agent attendus. Les neuf
répétitions donnent le même routage que leur entrée principale. Aucun agent
inadapté n'est sélectionné sur les cas sans compétence correspondante ; aucun
nouvel agent n'est proposé sur les 36 cas de correspondance claire.

- Temps médian des 72 propositions complètes : **3,963 s** ; p95 : **6,502 s**.
- Estimation du coût des 72 cas : **0,280747 USD**.
- Avec les répétitions : **0,317911 USD**, 165 581 tokens d'entrée et 30 466
  tokens de sortie. Calcul au barème interne de Mokaid, pas une facture fournisseur.
- 72/72 réponses principales respectent le schéma. Aucun appel au repli JSON
  n'est visible dans les compteurs : un appel modèle par entrée.
- 35/36 propositions nécessitant un nouveau profil contiennent ce profil.

**Défaut distinct trouvé :** `f17_kubernetes_incident_en` choisit correctement
`custom_agent` mais renvoie `custom_agent: null`. Le schéma permet ce cas et
Phoenix le remplace par sa proposition générique. Il manque donc un profil DevOps
utile malgré la bonne décision de routage. Le résultat 72/72 ne signifie pas que
les 72 propositions complètes sont parfaites. Une autre proposition de brevet
en anglais suppose une juridiction américaine non demandée ; c'est une hypothèse
supplémentaire, pas une erreur de sélection d'agent.

### Jev

Les trois réponses valides correspondent aux attentes : développeur pour une
application d'assurance en français, choix partiel pour une application mobile
en français, nouvel agent avec un effectif vide en hébreu. La seule réponse
principale obtenue est le cas simple d'effectif vide. Cela ne permet aucune
conclusion comparative de précision, de couverture linguistique ou de stabilité.

Les huit entrées effectivement soumises ont produit **13 tentatives HTTP** :

- 3 réponses HTTP 200 exploitables ;
- 9 réponses HTTP 429 (« Too many requests ») ;
- 1 réponse HTTP 502 non JSON.

Cinq reprises ont attendu au moins 60 secondes. Une a récupéré une réponse ;
les quatre autres ont encore échoué. Après trois entrées consécutives en échec,
le coupe-circuit prévu a arrêté les appels. Les 73 entrées restantes, répétitions
comprises, sont enregistrées comme **non tentées**, jamais comme erreurs du modèle.

Les trois tentatives réussies ont pris de 0,671 à 1,093 s chacune. L'une a toutefois
nécessité 61,605 s en incluant son attente de reprise. Ces quelques mesures ne
prouvent pas une amélioration du délai global : Jev ne produit ici ni brief, ni
profil, ni suggestion d'intégration, contrairement à Haiku. La réponse Jev ne
donne ni version exacte du modèle ni consommation facturable ; son coût reste
inconnu. Les sondes préliminaires sont conservées séparément et exclues des chiffres.

## Limites et point de méthode

Ce jeu est synthétique, écrit par un agent et relu indépendamment par un autre.
Il contient 24 familles corrélées entre langues, pas 72 problèmes indépendants
représentatifs des clients. Plusieurs demandes rendent la spécialité attendue
explicite. Il n'évalue pas l'exécution réelle, de grands effectifs, les fichiers
binaires, les demandes uniquement constituées de fichiers ni les permissions.
Les demandes vagues suivent la règle actuelle du produit, qui propose un agent
généraliste ; cela ne valide pas cette règle comme bonne expérience utilisateur.

Le prompt Jev est conçu pour ce composant et inclut une défense explicite contre
les instructions parasites. Le prompt Haiku reste inchangé. C'est une comparaison
de deux flux possibles, pas une comparaison de modèles à prompt identique.

Le runner observé v1.0.0 a repris les erreurs 429 mais pas le 502, alors que ce
dernier indiquait `Retry-After: 60`. L'entrée suivante est partie une seconde
après ce 502, ce qui peut avoir aggravé la limitation initiale. Les 429 ont ensuite
persisté malgré plusieurs attentes d'une minute. Ce point réduit la portée d'une
affirmation générale sur la disponibilité du fournisseur ; il ne fournit aucune
raison de remplacer immédiatement le dispatcher. Les erreurs de service ne
permettent pas de dire que Jev est moins précis.

## Conséquence pour Mokaid

1. Pas d'activation de Jev ni de changement du routage de production à l'issue
   de cette évaluation. La clé reste disponible dans `mokaid/jev-api-key`.
2. Le besoin d'amélioration concret observé est la présence et la pertinence du
   profil lorsqu'un nouveau spécialiste est proposé. Ce défaut est documenté ;
   aucun correctif de production n'a été inclus dans cette tâche d'évaluation.
3. Une réévaluation de Jev aurait du sens avec un accès dont les quotas sont
   connus et adaptés, puis des cas métier plus difficiles. Les résultats présents
   ne justifient pas d'ajouter cette dépendance au parcours de création de tâche.
4. Le code de production SQS contourne actuellement l'analyse HTTP du worker.
   Cette expérience isole le dispatcher LLM et ne prétend pas valider tout le
   chemin de production ou changer sa configuration.

## Reproduction et preuves

- Corpus : `apps/ai-worker/evals/jev_routing/cases.json`.
- Protocole : `apps/ai-worker/evals/jev_routing/PROTOCOL.md`.
- Mesures brutes : `results.jsonl` ; calculs : `summary.json`.
- Manifeste et empreintes : `manifest.json`.
- Source exacte utilisée : `runner-used-v1.0.0.py`, empreinte vérifiée contre le
  manifeste. Le runner maintenu est désormais v1.0.1, avec des protections du
  harnais ajoutées après l'expérience ; aucun résultat n'a été réécrit ou rejoué.
- Sondes initiales : `availability-probes.json`, hors benchmark.
- 20 tests locaux du harnais/scoring ; aucune nouvelle inférence nécessaire pour
  les rejouer. L'analyse des résultats est entièrement locale.

Références de conception : [API communautaire](https://www.jevai.org/docs),
[choix de compétences TypeSafe](https://docs.typesafe.ai/cookbooks/skill_suggestion),
[limites du modèle](https://docs.typesafe.ai/model-jaggedness/jev-1.13).
