# mokaid — AI Workforce OS
# Monorepo Makefile. Requires: docker, node >= 20, elixir >= 1.16, python >= 3.11

SHELL := /bin/bash
COMPOSE := docker compose

.PHONY: help dev dev.infra stop test lint format \
	db.setup db.migrate db.seed db.reset \
	web.dev web.install web.build web.test web.lint \
	api.dev api.install api.test api.lint \
	ai.dev ai.install ai.test ai.lint \
	assets.optimize assets.manifest \
	tf.fmt tf.validate

help: ## Show available commands
	@grep -E '^[a-zA-Z_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

## ---------- Full stack ----------

dev: ## Start full local stack (infra + all apps) via docker compose
	$(COMPOSE) up --build

dev.infra: ## Start only infrastructure services (postgres, minio, clickhouse)
	$(COMPOSE) up -d postgres minio clickhouse

stop: ## Stop all docker compose services
	$(COMPOSE) down

test: web.test api.test ai.test ## Run all test suites

lint: web.lint api.lint ai.lint ## Run all linters

format: ## Format all codebases
	cd apps/web && npm run format
	cd apps/api && mix format
	cd apps/ai-worker && ruff format app

## ---------- Database ----------

db.setup: ## Create and migrate the database
	cd apps/api && mix ecto.setup

db.migrate: ## Run pending migrations
	cd apps/api && mix ecto.migrate

db.seed: ## Seed demo data
	cd apps/api && mix run priv/repo/seeds.exs

db.reset: ## Drop, recreate, migrate and seed
	cd apps/api && mix ecto.reset

## ---------- Web (React / Vite) ----------

web.install: ## Install frontend dependencies
	npm install

web.dev: ## Start frontend dev server
	cd apps/web && npm run dev

web.build: ## Build frontend for production
	cd apps/web && npm run build

web.test: ## Run frontend tests
	cd apps/web && npm run test -- --run

web.lint: ## Lint + typecheck frontend
	cd apps/web && npm run lint && npm run typecheck

## ---------- API (Elixir / Phoenix) ----------

api.install: ## Install backend dependencies
	cd apps/api && mix deps.get

api.dev: ## Start Phoenix dev server
	cd apps/api && mix phx.server

api.test: ## Run backend tests
	cd apps/api && mix test

api.lint: ## Check backend formatting + compile warnings
	cd apps/api && mix format --check-formatted && mix compile --warnings-as-errors

## ---------- AI worker (Python / FastAPI) ----------

ai.install: ## Install AI worker dependencies
	cd apps/ai-worker && python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"

ai.dev: ## Start AI worker dev server
	cd apps/ai-worker && .venv/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port 8100

ai.test: ## Run AI worker tests
	cd apps/ai-worker && .venv/bin/pytest

ai.lint: ## Lint AI worker
	cd apps/ai-worker && .venv/bin/ruff check app

## ---------- 3D assets ----------

assets.optimize: ## Optimize GLB assets (gltfpack + KTX2)
	./scripts/optimize-assets.sh

assets.manifest: ## Regenerate the 3D asset manifest
	cd apps/web && npx tsx ../../scripts/generate-asset-manifest.ts

## ---------- Terraform ----------

tf.fmt: ## Format all terraform files
	terraform -chdir=infra/terraform fmt -recursive

tf.validate: ## Validate terraform modules (dev environment)
	terraform -chdir=infra/terraform/environments/dev init -backend=false && \
	terraform -chdir=infra/terraform/environments/dev validate
