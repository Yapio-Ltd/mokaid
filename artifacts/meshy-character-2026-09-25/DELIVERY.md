# Livraison des personnages Meshy — 25 septembre 2026

- PR fusionnée : https://github.com/Yapio-Ltd/mokaid/pull/18
- Commit de fonctionnalité : `239b8aa9fbee9f3409adac76e7cee25569459548`.
- Correctif de dépendance web : https://github.com/Yapio-Ltd/mokaid/pull/19
- Correctif de dépendance : `5b6d57ac9b82c7797b7e53b59f6d2a40d510516d`.
- Préservation de la livraison mail déjà active : https://github.com/Yapio-Ltd/mokaid/pull/20
- Commit combiné : `94d03e30c3008c2b5341ffc34ccb94a25cd26627`.
- Compatibilité du formatage avec Elixir 1.17 : https://github.com/Yapio-Ltd/mokaid/pull/21
- Commit final de production : `857c644c33a22f5caa65de13cedfbcb2a991e2b9`.
- Tous les contrôles de la PR passent : API, web, CRM, worker, infrastructure,
  politiques de déploiement, images Docker, moteur portable, macOS et Windows.
- Deux générations réelles (photo et description) ont réussi chez Meshy, jusqu'à
  la conversion native et au chargement dans le moteur Office à 1,75 m.
- Application native isolée compilée :
  `/tmp/mokaid-meshy-release-build/app/Mokaid.app` (version de développement locale).
  Les installateurs signés ne sont pas publiés par cette livraison serveur.
- L'application locale habituelle contient également Meshy et la nouvelle connexion
  mail : `/Users/olimservice/mokaid/apps/desktop/build/macos-debug/app/Mokaid.app`.
  Présence vérifiée dans le binaire des contrôleurs et caches QML des deux fonctions.
- Les deux secrets sont stockés dans AWS Secrets Manager, région `il-central-1`.
  La version utilisateur du secret webhook porte le label `AWSCURRENT`.
  Aucune valeur de secret n'est incluse dans le dépôt ou ce rapport.

L'endpoint est actif : `POST https://mokaid.com/api/webhooks/meshy` → HTTP 202.
Les contrôles publics vérifient aussi HTTP 401 pour la génération sans session,
HTTP 404 pour un média invalide et le maintien des protections des routes mail.
La CI finale `36124860899` et le déploiement `36126042678` sont entièrement verts.
Vérification finale le 25 septembre 2026 à 14:14, heure d'Israël : API 55,
worker 48, web 53 et CRM 13 sont stables, chacun avec une instance attendue et
active, sans instance en attente. Leurs images correspondent toutes au commit
final de production. Les six contrôles HTTP publics passent après le déploiement.
Le reçu complet est dans `production-verification.json`.

Une tâche éphémère utilisant exactement l'image, les secrets, le rôle et le réseau
de l'API 55 a vérifié : lecture authentifiée du solde Meshy, présence des deux
secrets, import du convertisseur natif, écriture et relecture d'un objet S3 sous
le préfixe autorisé. Le chiffrement KMS est confirmé. La version exacte de l'objet
de test a été supprimée et son absence vérifiée. Aucun job payant, agent ou espace
de production n'a été créé par cette sonde. Résultats dans
`production-runtime-smoke.json`, `production-http-checks.jsonl` et
`production-probe-cleanup.json`.

Le déploiement `36122767174` a validé les scans, le staging et la migration Meshy,
puis a refusé de remplacer une révision API modifiée pendant l'opération. La
tâche mail avait déployé API 53 et worker 47 directement. Aucun retour arrière
n'a été imposé. La PR 20 intègre exactement les 31 fichiers serveur de cette
livraison : 29 hashes identiques, deux fichiers partagés fusionnés sélectivement.
La version combinée passe les 346 tests API et les 16 tests mail du worker.
Une différence de formatage Elixir 1.20/1.17 sur une ligne du code mail a ensuite
été corrigée dans la PR 21, sans changement de comportement.

Le protocole de signature Meshy n'étant pas documenté dans les références
consultées, les notifications servent de signal de réveil : le serveur relit
systématiquement l'état auprès de l'API Meshy authentifiée. Le secret est stocké
et configuré, mais aucune validation cryptographique de signature n'est revendiquée.
Le polling permet à la génération de continuer indépendamment des webhooks.

Les personnages générés disposent de marche et d'une pose de repos ; les
animations spécifiques du catalogue (assis, café, téléphone) ne sont pas fournies.

Le premier déploiement a été arrêté avant mutation de production par le scan de
libexpat (CVE-2026-93990). Le runtime web a été corrigé à 2.8.5-r0, reconstruit
en arm64 et rescanné localement avec Trivy 0.69.3 : aucune vulnérabilité haute
ou critique corrigible détectée. Les contrôles de déploiement sont conservés.
