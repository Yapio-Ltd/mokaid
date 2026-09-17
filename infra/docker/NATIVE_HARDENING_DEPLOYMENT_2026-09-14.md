# Promotion du durcissement desktop natif — 14 septembre 2026

## Résultat : lot déployé et contrôlé, release desktop non publiée

Le candidat est le commit
[`4765db93fc399ed3919866b06f7a4d57c3854ba9`](https://github.com/Yapio-Ltd/mokaid/commit/4765db93fc399ed3919866b06f7a4d57c3854ba9).
La [PR nº 4](https://github.com/Yapio-Ltd/mokaid/pull/4) a été intégrée par avance
rapide dans `main` le **14 septembre 2026 à 15:36:56 UTC**. Les validations de la
PR et de `main` sont acquises. Le même SHA a été promu par avance rapide vers
`prod` après vérification des deux CI de `main`. Les CI `prod` sont également
réussies. Le déploiement AWS automatique a terminé avec succès le **14 septembre
2026 à 16:12:33 UTC**, en 18 min 40 s. Les contrôles indépendants ci-dessous
confirment ensuite les quatre services et leurs images réelles.

La référence complète avant cette promotion est
`d6f8eba891eef26ba6589ede3ab6c3c886e71815`, dont le déploiement précédent est
documenté dans le [rapport de production](PRODUCTION_VERIFICATION_2026-09-14.md).
Les quatre services exécutent désormais `4765db9`. Cette livraison serveur est
réelle ; elle n'est **pas** une publication d'installateurs desktop ni une
autorisation de couper l'expérience web.

## Preuves CI du commit candidat

| Exécution | État à la rédaction | Portée de la preuve |
| --- | --- | --- |
| [Desktop de la PR — 34861891408](https://github.com/Yapio-Ltd/mokaid/actions/runs/34861891408) | Réussie | Compilation, tests et préparation du runtime non signé sur Windows et macOS ; tests portables ASan/UBSan |
| [CI générale de la PR — 34861891444](https://github.com/Yapio-Ltd/mokaid/actions/runs/34861891444) | Réussie | Contrôles API, web, worker IA, CRM et constructions Docker prévus par la CI |
| [CI générale de `main` — 34863322202](https://github.com/Yapio-Ltd/mokaid/actions/runs/34863322202) | Réussie | Sept jobs réussis sur le SHA exact ; événement `push` |
| [Desktop de `main` — 34863322622](https://github.com/Yapio-Ltd/mokaid/actions/runs/34863322622) | Réussie | Trois jobs réussis sur le SHA exact ; événement `push` |
| [CI générale de `prod` — 34864391861](https://github.com/Yapio-Ltd/mokaid/actions/runs/34864391861) | Réussie | Prérequis du déploiement automatique satisfait |
| [Desktop de `prod` — 34864391899](https://github.com/Yapio-Ltd/mokaid/actions/runs/34864391899) | Réussie | Windows 6 min 24 s, macOS 8 min 40 s, portable 1 min 4 s |
| [Déploiement AWS — 34865148264](https://github.com/Yapio-Ltd/mokaid/actions/runs/34865148264) | Réussi | Événement `workflow_run`, source exacte `4765db9`, créé à 15:53:46 UTC ; job terminé à 16:12:33 UTC |

Les journaux des deux jobs natifs de la PR établissent les résultats suivants :

- [Windows, job 104035958777](https://github.com/Yapio-Ltd/mokaid/actions/runs/34861891408/job/104035958777) : **16/16 suites CTest réussies**, 35,42 secondes, à 15:30:51 UTC ; les sept tests de frontières entre modules passent également.
- [macOS, job 104035959000](https://github.com/Yapio-Ltd/mokaid/actions/runs/34861891408/job/104035959000) : **16/16 suites CTest réussies**, 47,74 secondes, à 15:28:48 UTC ; les sept tests de frontières entre modules passent également.

Le correctif MSVC final homogénéise le type `QByteArray` dans une réponse HTTP
de fixture QML ; il ne change pas son contenu. Les tests Windows ne sont donc
plus « en attente » pour ce commit. En revanche, ces jobs hébergés ne constituent
ni une installation sur machine physique, ni une notarisation, ni un test de mise
à jour signée. Le blocage local d'ASan avant `main`, documenté lors du développement,
ne doit pas être confondu avec les tests portables ASan/UBSan réussis en CI.

## Contenu du lot

- **Drive natif :** navigation par dossiers, fil d'Ariane, retour, corbeille et
  restauration de la ligne sélectionnée via les API existantes ; export limité
  à 32 MiB avec confirmation native de remplacement. Les écritures, flushes et
  synchronisations disque sont exécutés sur un worker ; la publication native
  atomique suit la vérification du compte, du workspace et de la destination.
- **Annulation et formulaires :** refus des réponses HTTP tronquées, des anciennes
  fenêtres de soumission et des résultats devenus périmés après changement de
  contexte. Le retour depuis un aperçu ouvre les Fichiers natifs ; le shell
  protège les téléchargements en cours contre une fermeture accidentelle.
- **Conversations :** API, worker et client natif transportent l'identifiant de
  conversation d'origine pour les messages et tâches. Les flux simultanés ne
  sont pas attribués par comparaison de leur texte. La saturation du budget de
  huit aperçus évince le plus ancien avec notice et resynchronisation, sans
  rejeter son futur message canonique.
- **Signature Mac :** ajout d'une sonde séparée, fermée par défaut, avec tests
  de sécurité synthétiques. Sa présence dans ce commit ne prouve pas l'exécution
  d'une signature/notarisation réelle et n'autorise aucune publication publique.

Les [preuves locales détaillées](../../apps/desktop/docs/native-hardening-2026-09-14.md),
la [couverture fonctionnelle restante](../../apps/desktop/application/features/PARITY.md)
et le [protocole de la sonde de signature](../../apps/desktop/docs/private-macos-signing-probe.md)
restent les références spécialisées ; leur état historique n'est pas un verdict AWS
pour cette nouvelle promotion.

Les parcours sont notamment couverts par les tests de
[Drive et contexte](../../apps/desktop/application/features/tests/feature_tests.cpp),
[publication des fichiers](../../apps/desktop/application/features/tests/prepared_download_tests.cpp),
[composants QML](../../apps/desktop/application/features/tests/feature_qml_tests.cpp),
[transport HTTP](../../apps/desktop/network/tests/api_tests.cpp),
[navigation des aperçus](../../apps/desktop/preview/tests/navigation_tests.cpp),
[conversations natives](../../apps/desktop/tests/office_controller_tests.cpp),
[périmètre des messages serveur](../../apps/api/test/mokaid_web/worker_chat_scope_test.exs),
[coordination du worker Phoenix](../../apps/api/test/mokaid/ai/agent_chat_worker_test.exs)
et [réponses du worker IA](../../apps/ai-worker/tests/test_direct_chat.py).

## Compatibilité du déploiement progressif

La comparaison Git exacte entre la production `d6f8eba891eef26ba6589ede3ab6c3c886e71815`
et le candidat `4765db93fc399ed3919866b06f7a4d57c3854ba9` ne contient **aucune migration
nouvelle, modifiée ou supprimée** dans `apps/api/priv/repo/migrations`. La migration
des sessions desktop appartient au déploiement précédent, pas à ce lot.

La revue indépendante est favorable à l'ordre **API, puis worker**.
`conversation_id` reste facultatif côté contrat serveur : les anciens producteurs
continuent à fonctionner. Les anciennes versions du worker et les exécutions
déjà engagées conservent néanmoins le comportement historique jusqu'à leur
remplacement ou leur achèvement. La corrélation stricte des nouvelles réponses
ne doit pas être présentée comme rétroactive pour ces exécutions ; le client natif
n'affiche pas les fragments de stream dépourvus d'identification exploitable.

La chaîne existante doit conserver ses contrôles de SHA, d'images immuables, de
scans, de staging isolé et de convergence ECS. Aucun rollback automatique de base
de données n'est introduit. La compatibilité de protocole examinée n'est pas une
preuve de panne réelle ou de rollback opérationnel réussi.

## Référence AWS avant promotion

La lecture des métadonnées ECS via SSO, avant promotion, confirme la référence
suivante dans `mokaid-prod` ; il s'agit encore de l'ancien code de production :

| Service | Révision | Déploiement principal | Tâches actives / souhaitées / en attente |
| --- | --- | --- | --- |
| API | 44 | PRIMARY, COMPLETED | 1 / 1 / 0 |
| Worker IA | 39 | PRIMARY, COMPLETED | 1 / 1 / 0 |
| Web | 45 | PRIMARY, COMPLETED | 1 / 1 / 0 |
| CRM | 5 | PRIMARY, COMPLETED | 1 / 1 / 0 |

Les quatre services ont le circuit breaker ECS activé et `rollback=true`.
Cette convergence est une référence avant changement, pas une validation des
nouvelles images ni de chaque fonction métier. Aucun nouveau digest, nouvelle
révision ECS ou résultat de sonde publique du candidat n'est affirmé ici.

Les seuls réglages applicatifs relevés sont `AUTH_MODE=dev_fallback`,
`MOKAID_DESKTOP_ONLY_BUSINESS=false` et
`DESKTOP_AUTH_WEB_BASE_URL=https://mokaid.com`. Le premier est le nom historique
du login local email/Bcrypt avec jetons Phoenix signés et vérifiés ; ce n'est pas
une désactivation de l'authentification. Le remplacer par Cognito sans migration
invaliderait les jetons émis par les parcours web existants. Aucun changement de
fournisseur ni rotation de clé n'est inclus dans ce déploiement.

Une revue statique ciblée a aussi relevé des sujets de durcissement web
préexistants, non corrigés par ce lot : absence de révocation du jeton web au
logout/changement de mot de passe, durée de sept jours, expiration non revérifiée
sur les sockets web déjà établis, inscription sans vérification d'email et limite
de connexion seulement générique par IP. Les garanties des sessions desktop
rotatives ne doivent pas être attribuées à ces sessions web historiques.

## Verdict AWS après promotion

Le [job réel 104046997566](https://github.com/Yapio-Ltd/mokaid/actions/runs/34865148264/job/104046997566)
est terminé avec `conclusion=success` ; il n'a pas été ignoré. Les étapes de
construction et publication des quatre images, les quatre scans ARM64, le staging
isolé des images exactes, le renouvellement OIDC, les migrations, les quatre
déploiements et le contrôle HTTP public ont chacune réussi. Les étapes de
récupération ont été normalement ignorées après succès : aucun rollback n'a été
déclenché par cette exécution. Les scans HIGH/CRITICAL avec correctif disponible
ne constituent pas une preuve d'absence de toute vulnérabilité.

Lecture indépendante après la fin du job, dans `mokaid-prod` :

| Service | Ancienne révision | Révision exécutée | Déploiement | Tâches actives / souhaitées / en attente |
| --- | --- | --- | --- | --- |
| API | 44 | 45 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |
| Worker IA | 39 | 40 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |
| Web | 45 | 46 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |
| CRM | 5 | 6 | PRIMARY unique, COMPLETED | 1 / 1 / 0 |

Les quatre services conservent le circuit breaker activé et `rollback=true`.
Chaque tâche et son conteneur ont été contrôlés `RUNNING`. Leur `healthStatus`
ECS reste `UNKNOWN`, pas `HEALTHY` : aucune santé applicative ne doit être déduite
de ce seul champ. Le worker n'a pas de target group ALB.

Les URI et digests des conteneurs exécutés correspondent exactement aux index
ECR du tag `4765db93fc399ed3919866b06f7a4d57c3854ba9` :

| Dépôt | Digest OCI exécuté et vérifié |
| --- | --- |
| mokaid-api | `sha256:c2a176cf581ac7576eed885e3cf779df2c5bf165c323798fc5500bfbdf48a3fb` |
| mokaid-ai-worker | `sha256:1adec493e2faca43db93a569f05688c6162d22c983cde2b9416c0cd1116eddd2` |
| mokaid-web | `sha256:ca761771ac8da7995fc6408129400c1554368d78d0f08343eea4637735af0676` |
| mokaid-crm | `sha256:c9755b25e1904b3379c1cfdecc51f2f9ff40795e3e504c6621980a013630ed28` |

Chaque index a aussi été résolu dans ECR vers un unique manifeste Linux ARM64,
sans télécharger les couches. ECS expose ici le digest de l'index OCI ; il ne
faut pas le confondre avec le digest du manifeste enfant.

API et web avaient une cible ALB unique `healthy` au premier contrôle final.
Le CRM avait encore une ancienne cible `draining` avec
`Target.DeregistrationInProgress` et une nouvelle cible `healthy` : le contrôle
strict a donc d'abord refusé de conclure. Après attente, le contrôle du CRM
réussi à **16:16:49 UTC** confirme une seule cible `healthy`. Aucun retrait forcé
ni changement de seuil n'a été effectué.

Le script [verify-production.mjs](../../.github/scripts/verify-production.mjs)
a réussi depuis GitHub, puis depuis la connexion locale après déploiement :
HTML prérendu/H1/canoniques pour accueil, tarifs et téléchargement ; sitemap
public excluant les pages privées ; `noindex`/`no-store` pour compte, connexion
et autorisation desktop ; 404 des routes inconnues ; santé API 200 et refus 401
des requêtes anonymes protégées. Ce n'est pas un test de tous les parcours
authentifiés, des paiements ou de réponses IA réelles.

La révision API 45 conserve exactement les trois réglages non secrets relevés
avant promotion, dont `MOKAID_DESKTOP_ONLY_BUSINESS=false`. La configuration
GitHub de bascule est également restée désactivée. L'étape de contrôle des
installateurs avant bascule a donc été ignorée normalement : ce n'est **pas** une
validation de leur disponibilité. Aucun tag desktop, binaire public ou appcast
n'a été créé par cette promotion.

## Limites inchangées

Le succès de ce lot ne suffit pas à activer le mode desktop-only : les bascules
restent désactivées tant que les téléchargements signés utilisables et les critères
d'acceptation ne sont pas satisfaits. Ce rapport ne valide pas la disponibilité
du CDN, la distribution publique, l'installation sur machines propres ou les
mises à jour signées.

Deux autorisations spécifiques restent sans réponse au point de rédaction :

- Ouvrir un dossier AWS Support gratuit pour la vérification CloudFront, avec le
  domaine et l'erreur technique seulement, sans secret ni contenu client. Aucun
  dossier n'a été soumis et le blocage n'a pas été contourné par un bucket public.
- Autoriser uniquement `main` en plus des tags dans l'environnement GitHub
  `desktop-signing-stable`, en conservant la revue du propriétaire, et le transit
  d'un artefact **non signé** conservé un jour dans Actions sur ce dépôt public.
  Cette permission est nécessaire à la sonde Mac isolée ; elle ne permet pas
  d'uploader un binaire signé, de publier une release ou de promouvoir un appcast.
  Le paramétrage GitOps correspondant doit rester cohérent avec la modification
  de l'environnement. Aucun de ces changements n'a encore été appliqué.

Pour la signature Windows, le [raccordement prévu](../../apps/desktop/docs/releases.md)
attend un compte Artifact Signing, un profil Public Trust et une identité
d'organisation effectivement validée. Les [prérequis officiels Microsoft](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart#prerequisites)
et la [restriction sur les abonnements gratuits/essai/sponsorisés](https://learn.microsoft.com/en-us/azure/artifact-signing/faq#can-i-use-artifact-signing-with-a-free-trial-or-sponsored-azure-subscription)
ont été revérifiés le 14 septembre 2026 : un abonnement Azure payant est requis.
La validation juridique doit être réalisée par le représentant de l'organisation,
avec ses informations réelles ; aucun abonnement, justificatif, compte ou nouveau
rôle Azure n'a été créé dans ce lot. Le choix d'un tenant et cette dépense ne sont
pas implicitement autorisés par le succès de la CI.

La cible de 60 FPS sur M1/Iris Xe, les machines NVIDIA et la parité complète des
32 écrans exigent toujours leurs validations dédiées. Une nouvelle exécution
locale de la sonde graphique via LaunchServices, pendant la CI `prod`, a confirmé
les 16 contrôles fonctionnels en Debug avec validation Metal. Le rapport local
`/private/tmp/mokaid-native-focused.pbid2g/report.json` contient 622 intervalles
sur 10 004 ms, mais `focusInterrupted=true` et
`performanceSampleQualified=false` : les timings ne constituent donc pas une
preuve de performance. Aucune erreur Metal n'a été signalée ; l'avertissement Qt
sur la création des profils WebEngine demeure. Aucun seuil n'a été assoupli.

Les tests de fichiers ne
garantissent pas la persistance de l'entrée de répertoire après une coupure de
courant ni la copie des ACL/attributs étendus. Un arrêt confirmé peut attendre
une synchronisation disque déjà lancée ; l'annulation interactive n'attend pas.

La promotion a été réalisée par les avances rapides Git autorisées et le workflow
automatique existant, sans push forcé, dispatch manuel ni changement de privilège.
Les contrôles indépendants ont lu seulement des métadonnées GitHub/AWS et des
réponses HTTP publiques, sans consulter de contenu client, table de production
ou secret. Les modifications Graphify préexistantes sont restées hors des commits.
