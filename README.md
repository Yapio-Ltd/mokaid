# mokaid — AI Workforce OS

**mokaid** is a real-time workspace where companies manage a workforce made of pure AI agents, human-linked agents, and hybrid agents — visualized in a live 3D office.

![Stack](https://img.shields.io/badge/stack-React%20%C2%B7%20Babylon.js%20%C2%B7%20Phoenix%20%C2%B7%20Python%20%C2%B7%20AWS-7c5cff)

## Monorepo layout

```txt
mokaid/
  apps/
    web/          React + TypeScript + Vite + Babylon.js frontend
    api/          Elixir Phoenix backend (JSON API + Channels + Presence)
    ai-worker/    Python FastAPI + LangGraph AI execution worker
  packages/
    design-tokens/  CSS design tokens (dark theme, purple accent)
    shared-types/   Shared TypeScript domain types & realtime events
  infra/
    docker/       Dockerfiles for all apps
    terraform/    Full AWS infrastructure (dev / staging / production)
  docs/           Architecture, API, database, realtime, security docs
  scripts/        3D asset optimization & manifest tooling
```

## Quick start (local development)

Prerequisites: Docker, Node >= 20, Elixir >= 1.16 (optional if using Docker), Python >= 3.11.

```bash
# 1. Start infrastructure (PostgreSQL + pgvector, MinIO)
make dev.infra

# 2. Backend
make api.install
make db.setup        # create + migrate + seed
make api.dev         # Phoenix on http://localhost:4000

# 3. Frontend
make web.install
make web.dev         # Vite on http://localhost:5173

# 4. AI worker
make ai.install
make ai.dev          # FastAPI on http://localhost:8100
```

Or run everything in Docker:

```bash
make dev
```

### Demo credentials (seeded)

| User | Email | Password | Role |
|---|---|---|---|
| Tom Jami | tom@mokaid.dev | mokaid-dev-1234 | Owner |

## Architecture

- **Frontend** — React/Vite SPA with an isolated Babylon.js 3D layer (procedural placeholder office & avatars until production GLB assets arrive). TanStack Router/Query, Zustand, Tailwind, Radix UI.
- **Backend** — Phoenix owns product state, permissions, workspaces, tasks, projects, billing and real-time events (Channels + Presence + PubSub). Oban for background jobs.
- **AI worker** — Python FastAPI service running LangGraph workflows with tool safety categories and human-in-the-loop approvals.
- **Data** — PostgreSQL (+ pgvector), S3 (MinIO locally), ClickHouse for analytics (optional profile).
- **Cloud** — Full AWS: ECS Fargate, RDS, S3 + CloudFront, Cognito, SQS, Secrets Manager, CloudWatch. See [docs/AWS_INFRASTRUCTURE.md](docs/AWS_INFRASTRUCTURE.md).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture.

## Commands

Run `make help` for the full list. Highlights:

| Command | Description |
|---|---|
| `make dev` | Full stack in Docker |
| `make test` | All test suites |
| `make lint` | All linters |
| `make db.reset` | Drop + migrate + seed |
| `make tf.validate` | Validate Terraform |
| `make assets.optimize` | Optimize GLB/KTX2 assets |

## 3D assets

Production GLB/KTX2 assets are not yet delivered. The 3D office and avatars are currently **procedurally generated placeholders** built at runtime, behind an `AssetManifest` abstraction — swapping in production assets requires no architecture change. See [docs/ASSETS_3D.md](docs/ASSETS_3D.md).

## License

Proprietary — © Yapio. All rights reserved.
