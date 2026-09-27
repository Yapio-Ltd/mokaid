# Validation serveur — Mail Center, 27 septembre 2026

Le paquet reproduit **51 fichiers** du snapshot figé `/private/tmp/mokaid-mail-center-release-20260927`, appliqués au commit `4716998a35123c85e19bdbe2013e8f4ff3d69669`. Il contient le parcours Google natif, le pont Google de lecture autorisée pour les agents, et les fonctions Mail de lecture, dossiers, pièces jointes, actions et envoi.

Cette preuve de construction ne certifie pas à elle seule un déploiement, une connexion à chaque fournisseur ou un envoi réel.

## Vérification de production ajoutée

Le [reçu de production](production-verification.json) confirme séparément le déploiement ECS : **API révision 58 et worker révision 51**, chacun avec un rollout `COMPLETED`, une tâche active, aucune tâche en attente et le digest attendu relu sur la tâche. Les quatre migrations Mail Center sont présentes en base ; la tâche de migration s'est terminée avec le code 0. Les sondes publiques confirment la santé du service et le refus des routes Mail sans authentification.

La [vérification réelle de lecture](live-mail-verification.json) confirme un compte Gmail actif, **106 messages synchronisés** et le téléchargement réussi d'une pièce jointe de **690 octets**. Le message choisi n'avait pas de corps de texte ; cette preuve ne certifie donc pas un rendu HTML réel. Aucune mutation fournisseur et aucun envoi de courriel n'ont été effectués. Les vérifications IMAP, SMTP, Graph et d'envoi restent des tests avec fixtures.

L'application native compilée est disponible dans le workspace. Le contrôle à l'écran avec le compte réel reste bloqué par le verrouillage du Mac ; les captures livrées proviennent des tests natifs avec fixtures. Le détail de ces tests est dans [README.md](README.md).

## Fichiers de preuve

- [release-manifest.json](release-manifest.json) : liste exhaustive, SHA-256 de chaque fichier avant/après, vérifications, images et journaux.
- [snapshot-source-manifest.json](snapshot-source-manifest.json) : copie exacte du manifeste d'origine, laissé inchangé.
- [mail-server-release.patch](mail-server-release.patch) : patch de 51 chemins, sans modification étrangère au périmètre retenu.
- [api-tests-final.txt](api-tests-final.txt) : **104 tests API réussis**.
- [worker-tests-final.txt](worker-tests-final.txt) : **184 tests Python réussis**, couvrant Mail et le pont Google.

Le coordinateur a confirmé la fin des deux sessions avec le code de sortie 0 avant l'archivage de ces journaux. Les validations de protocoles et d'envoi utilisent des fixtures ; aucune mutation ni aucun courriel de test sur une boîte utilisateur n'est requis pour les reproduire.

## Vérification du contenu

Vérifications effectuées sur les octets du snapshot, indépendamment des modifications concurrentes du workspace :

1. Les SHA-256 des 51 fichiers correspondent au manifeste source.
2. Le patch contient exactement ces 51 chemins.
3. `git apply --reverse --check` réussit contre le snapshot isolé.
4. `git apply --check`, puis l'application réelle du patch dans un répertoire temporaire contenant les versions de base, réussissent.
5. Les 51 fichiers reconstruits correspondent tous aux SHA-256 du snapshot.
6. Les **2 529 autres fichiers source présents dans le contexte** correspondent au commit de base. Les 62 fichiers de cache Python/pytest produits par les tests sont exclus de cette comparaison et du patch.
7. L'unique adaptation de contexte de construction est le `.dockerignore` racine : copie du fichier `infra/docker/api.Dockerfile.dockerignore` du commit de base. Son hash est enregistré dans le manifeste ; ce n'est pas une modification du code livré.
8. `apps/ai-worker/app/main.py` conserve intégralement la base et ajoute uniquement quatre fonctions de routes authentifiées : `/mail/send`, `/mail/message/action`, `/mail/attachment`, `/mail/message/detail`. Les modifications concurrentes de dispatcher/Jev ne sont pas incluses.

Le manifeste original et les 51 fichiers du snapshot ont été revérifiés après l'assemblage ; aucun n'a été modifié par cette tâche.

SHA-256 du patch :

```text
3343a31635bae7a80c38e045e5f645b00e89c20c7aa675799af93b7a44a0bde9
```

Empreinte de l'ensemble des 51 couples chemin/hash, selon la méthode décrite par le manifeste :

```text
75e2c39d34fd84667f83e1151722589f79510b51bc4e34e5b39929d9bb2f4fb5
```

Pour reconstruire les sources, utiliser un checkout propre du commit de base, appliquer le patch, puis recalculer les SHA-256 indiqués dans `files`. Pour reproduire le contexte API du builder historique, copier également le `.dockerignore` indiqué ci-dessus. Ne pas utiliser le workspace partagé et ses modifications non sélectionnées comme contexte de publication.

## Images construites

Les identifiants et plateformes ont été relus avec `docker image inspect`.

| Image | Plateforme | Identifiant local |
|---|---|---|
| API | linux/arm64 | `sha256:b19ac5da559b6136ff4263421eae6af186b88be81e672b470f89e1d36e4e54d1` |
| Worker | linux/arm64 | `sha256:f40003a714a7590ba1c3da603ec62864c82480b99717bf30e87c4bb5232859a1` |

Le coordinateur a également confirmé un smoke test du worker : quatre routes Mail authentifiées et HTML inerte, sans appel fournisseur. Les identifiants ci-dessus sont des IDs d'images locales ; ils ne constituent pas des digests de manifeste de registre ni une preuve de rollout ECS.

## Comportement vérifié et limites

- **Lecture et dossiers.** Recherche, filtres, tri et pagination portent sur le cache synchronisé, avec 200 messages au maximum par page. Les compteurs affichés sont ceux de ce cache, pas des totaux complets garantis du fournisseur pendant l'import. Un message Gmail portant plusieurs labels système peut appartenir à plusieurs dossiers.
- **Messages déjà présents.** L'ouverture d'un ancien message tente de récupérer son HTML, ses pièces jointes et ses en-têtes RFC auprès du fournisseur, puis conserve les données. En cas d'échec, l'API expose `meta.hydration_error` avec le contenu déjà disponible ; elle ne prétend pas avoir récupéré des données manquantes.
- **Historique.** L'import est borné et progresse au fil des cycles. Gmail traite une page de changements récents en parallèle d'une page d'historique ; les nouveaux messages n'attendent donc pas la fin de cet historique. Graph maintient des curseurs pour les six dossiers standard. IMAP découvre les dossiers standard reconnus et importe les UID par lots. Les dossiers personnalisés arbitraires ne sont pas tous représentés comme dossiers dédiés.
- **Mises à jour externes.** Les tombstones Gmail/Graph retirent uniquement le cache du compte et, pour un déplacement Graph, du dossier concerné. IMAP suit les disparitions sur un maximum de 10 000 UID importés par dossier ; des éléments plus anciens hors de cette fenêtre peuvent rester en cache. La synchronisation n'est pas présentée comme instantanée ou exhaustive en toute circonstance.
- **Analyse IA.** Le triage vise les nouveaux messages Inbox ; l'historique, les drapeaux et les rafraîchissements déjà connus sont marqués pour éviter une réanalyse répétée. Les mises à jour de métadonnées conservent les analyses déjà stockées.
- **Pièces jointes.** Téléchargements liés au workspace, au compte, au message et à son manifeste enregistré ; aucun URL libre n'est accepté. Limite de 20 MiB par téléchargement et de 30 MiB pour le MIME IMAP lu. Graph parcourt au maximum dix pages de cent pièces jointes ; un résultat incomplet devient une erreur explicite. Les pièces jointes envoyées conservées chiffrées peuvent être relues sans renouveler le jeton fournisseur.
- **HTML.** Un parseur reconstruit un sous-ensemble de balises et de styles. Scripts, iframes, images et ressources distantes automatiques sont retirés. Seuls des liens HTTP(S) et mailto validés sont conservés. Le renderer natif conserve sa propre protection contre le chargement de ressources.
- **Actions.** Lecture, étoile, archivage, spam et corbeille sont appliqués au fournisseur avant mise à jour locale. La corbeille est une opération réversible ; aucune route de purge n'est ajoutée. Les déplacements IMAP nécessitent les capacités MOVE et UIDPLUS ainsi qu'un dossier cible reconnu ; sinon l'action est signalée comme non prise en charge.
- **Envoi.** La boîte d'envoi durable distingue succès, rejet et livraison incertaine. Les échecs de transport après dispatch ne provoquent pas de renvoi automatique. Les droits `mail.send` et `mail.manage` sont contrôlés séparément ; les connexions ne créent pas d'autorisations automatiques pour les agents.
- **Autorisations fournisseur.** Des comptes Microsoft historiquement limités à Mail.Read nécessitent un nouveau consentement pour Mail.ReadWrite/Mail.Send. Les restrictions de consentement Google, les quotas et la disponibilité des fournisseurs restent des conditions externes.

Les tests de fixtures ne remplacent pas une vérification réelle des comptes connectés après déploiement. Les preuves éventuelles de rollout, de connexion ou de lecture réelle doivent être ajoutées séparément par le coordinateur.
