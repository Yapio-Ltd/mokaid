# Authentification web et desktop — vérification locale

## Corrections

- Sessions web opaques et révocables ; seule l'empreinte SHA-256 des identifiants aléatoires est conservée en base. Cookie chiffré `HttpOnly`, `SameSite=Lax`, `Secure` en production. `localStorage` conserve un marqueur CSRF, jamais le bearer.
- Les écritures par cookie exigent une origine autorisée et un jeton CSRF. La connexion exige une origine autorisée. Les WebSockets web utilisent le cookie et la validation CSRF de Phoenix ; les identifiants desktop restent dans leurs en-têtes.
- Déconnexion réellement révoquée en base. Changement de mot de passe : révocation des sessions web/desktop, fermeture des sockets, nouvelle session pour le navigateur ayant confirmé son mot de passe. Les autres onglets rechargent leur état après un changement de session.
- Inscription atomique avec son espace de travail ; mot de passe obligatoire pour un compte local ; email normalisé ; validation avant bcrypt ; maximum de 72 octets pour éviter sa troncature. Erreurs de connexion génériques, y compris pour un compte désactivé, et vérification bcrypt factice pour un compte absent.
- Google : PKCE S256, état unique lié au navigateur et au redirect exact, `email_verified` obligatoire, rejet d'une association à un autre identifiant Google et d'un compte inactif. Réponses OAuth sensibles absentes des journaux.
- Les réponses HTTP tardives ne détruisent plus une nouvelle session. Une session expirée renvoie vers la connexion. Le proxy Vite conserve cookies, Origin, CSRF et Set-Cookie ; seuls les cookies d'affinité AWSALB sont retirés.
- Les quotas utilisent l'adresse réellement observée par l'ALB uniquement lorsque le pair TCP appartient aux CIDRs ALB explicitement configurés. Le dernier élément XFF est retenu ; les éléments précédents, contrôlables par le client, sont ignorés. Une installation sans configuration ne fait confiance à aucun en-tête transmis.

Contrat desktop préservé : navigateur externe, consentement, code à usage unique lié au vérificateur PKCE et au callback loopback, accès de dix minutes, rotation des refresh tokens, révocation de la famille en cas de rejeu.

## Résultats

- Suite API complète : **254 tests réussis**, dont six régressions proxy : préfixe falsifié, pair direct/non configuré, IPv4/IPv6, CIDRs/en-têtes invalides ou dupliqués, quotas HTTP réellement indépendants par client observé.
- Suites web auth/compte/navigation : **53 tests réussis**.
- Syntaxe Nginx validée avec `nginx:1.30.4-alpine`, réseau désactivé et configuration montée en lecture seule.
- `terraform -chdir=infra/terraform/environments/prod validate -no-color` : configuration valide avec les providers locaux AWS 5.100.0 et random 3.9.0 ; aucun plan/apply effectué.
- TypeScript et build web de production : réussis (avertissement de taille des chunks 3D).
- Chrome réel avec serveurs/base temporaires locaux : formulaire d'inscription, cookie HttpOnly, absence de bearer dans localStorage, refus CSRF, heartbeat WebSocket authentifié via Vite, consentement desktop, véritable callback HTTP loopback, échange PKCE, rotation, déconnexion/révocation web, indépendance puis révocation desktop. Formulaire de connexion par mot de passe et déconnexion propagée entre onglets également vérifiés. Aucun `pageerror`.
- Contrat HTTP Google avec `Req.Test` : vérificateur transmis et adresse non vérifiée refusée. Aucun compte Google/Cognito réel connecté.

## Reproduction

PostgreSQL local avec pgvector ; bases jetables `mokaid_test` et `mokaid_auth_smoke`.

```sh
# apps/api — DATABASE_URL pointe vers la base locale de tests
MIX_ENV=test mix test

# apps/api — DATABASE_URL=postgres://...@127.0.0.1:PORT/mokaid_auth_smoke
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
MIX_ENV=test mix run --no-start scripts/auth-smoke-server.exs

# racine du dépôt, autre terminal
VITE_API_URL='' VITE_WS_URL='/socket' VITE_DEV_PROXY_TARGET=http://127.0.0.1:4017 npm exec --workspace=@mokaid/web -- vite --host 127.0.0.1 --port 5177
node apps/web/scripts/auth-smoke.mjs

npm exec --workspace=@mokaid/web -- vitest run src/test/browser-auth.test.ts src/test/account-portal.test.tsx src/test/account-routing.test.ts src/test/desktop-rollout.test.ts src/test/session-entry.test.ts
npm exec --workspace=@mokaid/web -- tsc --noEmit
npm run build --workspace=@mokaid/web
```

Chrome installé est utilisé avec `channel: 'chrome'`. Le script refuse les hôtes non loopback et génère uniquement des comptes de test.

## Mise en service et limites

Appliquer `20260915000001_create_web_sessions.exs` et livrer API/site ensemble. Les anciennes sessions web sans registre de révocation sont intentionnellement invalidées : une nouvelle connexion sera nécessaire. Les sessions desktop existantes conservent leur contrat.

Vérifier les origines HTTPS dans `CORS_ORIGINS`, `PHX_HOST` et `DESKTOP_AUTH_WEB_BASE_URL`, ainsi que les redirect URIs autorisés chez Google. Le mode local existant `AUTH_MODE=dev_fallback` reste distinct de Cognito ; aucun changement de fournisseur effectué. Aucun déploiement public réalisé.

L'ingress décrit par Terraform route `/api/*` et `/socket/*` directement de l'ALB vers ECS API ; le groupe de sécurité API n'autorise sur le port applicatif que celui de l'ALB. Nginx sert le HTML et les fichiers du site, sans normaliser l'IP API. Le module WAF présent contient des autorisations géographiques/hôtes/webhooks, sans `rate_based_statement`.

Le chemin API à un seul proxy est cohérent avec `modules/stack/main.tf` (`enable_cloudfront = false` par défaut, sans activation dans `environments/prod/main.tf`) et `modules/cloudfront/main.tf` : ses seules origines sont S3, sans origine ALB ni comportement `/api`. Vérification publique le 15 septembre 2026 à 21:16 UTC : DNS A `16.164.189.99`/`51.17.141.20`, `/api/health` en HTTP 200 avec cookies d'affinité ALB, sans en-tête CloudFront `Via`/`X-Amz-Cf-*`/`X-Cache`. Le DNS externe ne publie pas de CNAME ; sa console et l'état AWS actif n'ont pas été consultés. Ces observations complètent le contrat du dépôt sans remplacer la vérification des attributs à la livraison.

Le module ALB fixe maintenant `xff_header_processing_mode = "append"` et `enable_xff_client_port = false`. ECS API reçoit `MOKAID_TRUSTED_ALB_CIDRS` depuis les CIDRs exacts des sous-réseaux publics utilisés par cet ALB. Le plug s'exécute avant les limiteurs Phoenix et remplace `conn.remote_ip` seulement pour ces pairs et un dernier élément XFF valide. Un en-tête ambigu conserve l'adresse TCP. Cette confiance suppose le chemin ALB unique et la restriction de groupe de sécurité vérifiés dans les modules du dépôt : préserver ces conditions lors de la livraison et ne pas configurer tous les réseaux privés ou `0.0.0.0/0`. Les attributs du cloud actif n'ont pas été interrogés et aucune ressource cloud n'a été modifiée ; livrer cette configuration Terraform avec l'API pour activer la correction en production.

Les compteurs Hammer existants sont en ETS, donc locaux à chaque processus API : les seuils testés sont par client et par instance, sans quota global partagé entre réplicas. La configuration production autorise une à deux instances. Un plafond global strict demanderait un stockage partagé ou une règle WAF dédiée.

Le Nginx livré avec le site utilise désormais `Referrer-Policy: no-referrer` pour les pages d'authentification, OAuth, compte et leur shell SPA, en conservant l'héritage des autres en-têtes. La validation HTTPS réelle et l'authentification auprès des fournisseurs restent à confirmer dans l'environnement de livraison.

## Références primaires consultées

- [RFC 8252 — OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252) : navigateur externe, PKCE et callback loopback.
- [RFC 9700 — OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700) : liaison des réponses, prévention du rejeu, rotation des refresh tokens.
- [OWASP — Session Management](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) : cookies protégés, identifiants aléatoires, renouvellement et invalidation serveur.
- [AWS — ALB X-Forwarded headers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/x-forwarded-headers.html) : mode append et dernier élément observé par l'ALB, option de conservation du port client.
