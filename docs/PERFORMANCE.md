# Performance

## Frontend budgets

| Metric | Budget |
|---|---|
| Initial JS (gzip, without Babylon chunk) | < 300 KB |
| Babylon chunk (lazy) | loaded only on pages with 3D |
| First Contentful Paint | < 2s on 4G |
| 3D frame rate | 60 FPS target, 30 FPS floor |

Techniques:

- Vite manual chunks: `babylon`, `charts`, `vendor` split from the app bundle.
- The 3D scene is created once and lives outside the React render cycle; agent updates are pushed imperatively (`updateAgents`), bubbles are absolutely-positioned HTML driven by projected coordinates — no per-frame React renders.
- Procedural office uses shared materials and simple meshes; final GLB assets must ship Draco + KTX2 (see `scripts/optimize-assets.sh`) with instancing for repeated furniture.
- FPS is monitored in-scene; a sustained drop should trigger quality reduction (shadows off first), and WebGL failure falls back to the 2D team view.
- TanStack Query caching with realtime invalidation avoids polling.

## Backend

- Read paths hit denormalized status columns; history tables are write-only in hot paths.
- All workspace-scoped tables indexed on `workspace_id` (+ composite indexes on status/assignee for task boards).
- pgvector IVFFlat index for knowledge search.
- Oban for anything slow (ingestion, aggregation, exports) — API requests never block on AI work; runs are dispatched async via SQS.
- Phoenix Channels broadcast compact ID-based payloads; clients fetch details on demand.

## Infrastructure

- ECS autoscaling on CPU (target 65%); ALB sticky sessions for WebSocket affinity.
- CloudFront caches the SPA and 3D assets at the edge (immutable hashed filenames).
- RDS gp3 storage with autoscaling up to 100 GB; Performance Insights enabled.
- Container Insights + CloudWatch alarms on CPU/memory/5xx/DB CPU.

## Load-testing checklist (pre-launch)

1. 500 concurrent WebSocket connections per API task.
2. Kanban drag/drop with 1k tasks per board.
3. 50 simultaneous AI runs with approvals.
4. Knowledge search P95 < 200 ms at 100k chunks.
