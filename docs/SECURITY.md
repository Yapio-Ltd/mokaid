# Security

## Authentication

- **Production**: Amazon Cognito User Pool. The SPA obtains JWTs (SRP/OAuth code flow); Phoenix validates signatures against the pool JWKS, checks `aud`/`iss`/`exp`, and maps `cognito_sub` to a local user.
- **Development**: bcrypt-hashed password login issuing signed Phoenix tokens (`AUTH_MODE=dev_fallback`). Never enabled in production builds (`runtime.exs` forces `cognito`).

## Authorization

- Role-based: `Owner`, `Admin`, `Manager`, `Member`, `Viewer` with a `role_permissions` matrix checked in `Mokaid.Permissions`.
- Workspace isolation: `WorkspaceScope` plug rejects any request for a workspace the user is not a member of; all Ecto queries filter by `workspace_id`.
- Channel joins re-verify membership (topics are workspace/task/agent scoped).
- Worker endpoints use a dedicated bearer token stored in Secrets Manager, distinct from user auth.

## AI safety

- Tool calls risk-scored; external side effects (email, social, purchases) always require human approval; unknown tools are fail-closed HIGH risk.
- Approval decisions and AI actions are written to `audit_logs`.
- Agents only access knowledge items allowed by `knowledge_permissions`.

## Transport & storage

- TLS everywhere (CloudFront + ALB, `ELBSecurityPolicy-TLS13-1-2-2021-06`).
- S3: Block Public Access on all buckets, SSE-KMS, presigned URLs for uploads/downloads (short expiry).
- RDS: private subnets only, KMS-encrypted storage, no public accessibility.
- Secrets: AWS Secrets Manager, injected into ECS tasks at start; never in images or env files committed to git.

## Application hardening

- CORS restricted to configured origins (`Corsica`).
- Rate limiting per IP/token (`Hammer`).
- `drop_invalid_header_fields` on the ALB; request IDs on every response.
- Input validation via Ecto changesets (API) and Zod (frontend).

## Auditability

`audit_logs` records actor, action, entity, workspace, IP and diff metadata for sensitive operations (role changes, deletions, AI approvals, billing changes).
