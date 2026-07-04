# Contributing

## Getting started

```bash
git clone https://github.com/Tomyshh/mokaid.git && cd mokaid
make dev            # full stack via docker compose
# or see docs/DEPLOYMENT.md for native app commands
```

## Repository layout

See `README.md`. Rule of thumb: shared contracts go in `packages/`, app code stays in its `apps/*` folder, infrastructure in `infra/`.

## Workflow

1. Branch from `main`: `feat/<scope>`, `fix/<scope>`, `chore/<scope>`.
2. Keep commits small and descriptive (imperative mood: "add task board filters").
3. Open a PR — CI must pass (web typecheck/tests/build, api format/compile/tests, worker ruff/pytest, terraform fmt/validate).

## Quality gates

| App | Commands |
|---|---|
| web | `npm run typecheck`, `npm run lint`, `npm run test` (workspace `apps/web`) |
| api | `mix format`, `mix compile --warnings-as-errors`, `mix test` |
| ai-worker | `ruff check app tests`, `pytest` |
| terraform | `terraform fmt -recursive`, `terraform validate` |

Or from the root: `make lint`, `make test`, `make format`.

## Conventions

- **Frontend**: components in `components/`, route pages in `pages/`, hooks colocated in `api/hooks.ts`; Tailwind classes reference design tokens (`bg-surface`, `text-text-muted`, …) — never hardcode colors. 3D code stays in `src/three/` and must not import React.
- **Backend**: business logic in contexts (`lib/mokaid/`), controllers stay thin, every workspace query filters by `workspace_id`, broadcast realtime events after successful writes.
- **Worker**: new tools register in `app/tools/registry.py` **and** must have a risk level in `app/policies/approval.py` (unknown tools are treated as HIGH).
- **Migrations**: additive only; destructive changes need a two-step deploy.
- **Secrets**: never committed. Use `.env` locally (gitignored), Secrets Manager in AWS.
