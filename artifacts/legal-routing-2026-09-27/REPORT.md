# Demande juridique attribuée à Sira : diagnostic et correction

## Réponse au signalement

Deux constats distincts : les corrections précédentes étaient locales, et le
parcours utilisé par Moked comportait un défaut de routage supplémentaire.

Le binaire ouvert est le build desktop local `macos-debug`, configuré avec
`MOKAID_API_ORIGIN=https://mokaid.com`. Le cache de sa conversation confirme la
demande à 05:55:13 UTC, la réponse juridique de Moked, puis la création de la
mission à 05:55:23 UTC. Il confirme aussi les rôles Legal Specialist de Taya et
Software Engineer de Sira. Sira possède des compétences acquises de recherche,
rédaction, reporting et données, ainsi qu'une spécialité apprise `document`.

Le client transmet l'agent recommandé par `/api/dispatch/analyze` à
`/api/dispatch/confirm`. L'affichage retrouve cet agent par son identifiant ; il
ne prend pas simplement le premier avatar de la liste. La conversation Haiku
prépare le brief mais ne choisit pas elle-même l'agent.

Dans la configuration de production du dépôt, l'exécution utilise SQS. Le
dispatcher consultait le worker pour la sélection uniquement en mode `http` :
il utilisait donc les règles locales en mode `sqs`, même si la conversation
utilisait bien Haiku. Les tests précédents du worker ne couvraient pas ce choix
de transport de production.

La demande brute avec « lois », « droits » ou « obligations légales » ne détectait
pas le domaine juridique dans ces règles. Un brief développé avec « recherche »,
« document » ou « rapport » pouvait favoriser les compétences génériques de
Sira. Une reproduction avant correction avec les profils correspondants donne
effectivement **Sira** pour « Fais un rapport de recherche sur les lois de
protection des données » ; après correction, elle donne **Taya**.

Le brief complet de la mission photographiée n'est plus présent dans le cache
de conversation après lancement. La cause est donc corroborée par le chemin de
code, les profils et des reproductions, sans prétendre disposer d'une trace
serveur complète de cette affectation historique. La lecture des révisions ECS
a échoué parce que la session AWS SSO a expiré.

## Changements

1. La sélection synchrone consulte maintenant le worker avec URL et jeton valides
   sous `dispatch: :http` **et** `dispatch: :sqs`. Le transport d'exécution reste
   celui configuré ; le mode hors ligne et l'absence de jeton ne font aucun appel.
2. Les règles de secours reconnaissent les variantes françaises de loi, droit,
   légal, législation et les mots anglais law/laws. Pour une demande juridique,
   le format rapport/recherche/document ne supplante plus le domaine juridique.
   Une véritable analyse de dataset et la construction d'un site restent des
   travaux Data/Engineering, même si leur sujet est juridique.
3. Le prompt Haiku distingue le domaine professionnel de la recherche et de la
   rédaction nécessaires à son traitement. L'absence d'un pays dans une courte
   liste de compétences ne suffit pas à déclarer le spécialiste inadapté.
4. Un autre défaut desktop a été reproduit : une sélection modifiée pendant les
   1,2 seconde d'animation pouvait utiliser l'ancien lancement programmé. Le
   timer exige désormais le même brief, le même agent et l'absence d'avertissement.
   Ce défaut n'est pas présenté comme la cause prouvée de la capture.

## Vérification

- Régressions API avec Sira/Taya et les compétences apprises de Sira : demande
  exacte avec fautes, variantes françaises, rapport juridique, protection des
  données et trois briefs complets réellement générés par le chat.
- Contrôles inverses : site de cabinet juridique et analyse statistique d'un
  dataset de lois restent orientés vers les compétences techniques.
- Tests desktop : Taya recommandée malgré Sira première dans la liste, aucun
  lancement automatique pour `user_choice`, sélection changée pendant le timer
  bloquée. Suite Qt : 13 cas, 15 vérifications avec initialisation/nettoyage.
- Python : 69 tests ciblés réussis ; Ruff passe.
- API : 72 tests ciblés réussis ; formatage Elixir validé.
- Essais réels Haiku : huit demandes ciblées puis trois parcours complets
  conversation → brief → sélection, sans création de mission ni exécution.

Le replay final ciblé (`final-results.jsonl`) donne les huit routes directes
attendues. Les trois briefs générés proposent Taya : deux en affectation directe,
un en `user_choice` avec une autre proposition juridique. **10/11** respectent
donc l'attente stricte d'affectation directe ; aucune demande juridique n'est
envoyée vers Sira. Le choix partiel reste soumis à une sélection explicite.
Cette hésitation résiduelle est conservée dans les résultats ; elle ne prouve
pas une erreur de domaine et ne permet pas de revendiquer une parfaite stabilité
du mode de sélection.

Le corpus plus large de 72 cas et neuf répétitions a été rejoué séparément dans
`broad-regression/` : **81/81 réponses valides avec le mode et l'agent attendus**,
dont neuf répétitions cohérentes. Les mesures finales sont dans `verification-summary.json`.
Ces cas sont synthétiques et connus après diagnostic ; ce sont des régressions,
pas une preuve d'infaillibilité sur des demandes inédites.

## État de livraison

Le code est corrigé dans le workspace. Aucun push, déploiement, redémarrage du
desktop utilisateur ou changement de la mission existante n'a été effectué.
Pour activer le routage corrigé sur mokaid.com, les changements API et worker
doivent être livrés ensemble avec les gardes du tour précédent. Le garde du timer
desktop nécessite ensuite une nouvelle compilation de l'application.
