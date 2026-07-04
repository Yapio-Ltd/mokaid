# Database

PostgreSQL 16 with extensions `uuid-ossp`, `citext`, `vector` (pgvector). All primary keys are UUIDs; all workspace-owned tables carry `workspace_id` and are indexed on it.

## Domain map

| Domain | Tables |
|---|---|
| Identity | `users`, `workspaces`, `workspace_members`, `member_invites`, `roles`, `permissions`, `role_permissions`, `teams` |
| Agents | `agents`, `agent_skills`, `agent_capabilities`, `agent_status_events` |
| Tasks | `tasks`, `subtasks`, `task_assignments`, `task_comments`, `task_attachments`, `task_activity_events`, `task_execution_runs`, `task_approval_requests` |
| Projects | `projects`, `project_members`, `project_agents`, `project_files`, `project_activity_events` |
| Drive | `files`, `drive_items`, `drive_item_versions`, `drive_item_permissions`, `drive_item_comments`, `drive_item_activity_events` |
| Knowledge | `knowledge_categories`, `knowledge_items`, `knowledge_chunks` (vector 1536), `knowledge_permissions` |
| Calendar | `calendar_events`, `leave_requests` |
| Integrations | `integration_providers`, `integration_connections`, `webhook_events` |
| Billing | `billing_plans`, `subscriptions`, `invoices`, `usage_events` |
| Ops | `audit_logs`, `notifications`, `oban_jobs` |

## Notable design decisions

- **Agents unify humans and AIs**: `agents.kind` ∈ `ai | human_linked | hybrid`; `linked_user_id` references `users` when human-linked. A DB check constraint enforces consistency.
- **Status history**: `agent_status_events` and `task_activity_events` are append-only; current status is denormalized on the parent row for cheap reads.
- **Vector search**: `knowledge_chunks.embedding vector(1536)` with an IVFFlat index; chunks reference `knowledge_items` which reference `files`.
- **Soft delete for Drive**: `drive_items.status` ∈ `active | trashed | deleted` with `trashed_at` for the trash bin.
- **Billing usage**: `usage_events` are raw and append-only; aggregation happens in a nightly Oban job.

## Migrations & seeds

```bash
make db.setup      # create + migrate + seed
make db.migrate
make db.seed       # demo workspace with Tom Jami + 10 agents
make db.reset
```

Migrations live in `apps/api/priv/repo/migrations/`, grouped per domain.
