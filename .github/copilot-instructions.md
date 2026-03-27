---
description: "Repository coding conventions and contribution guidance for the voice practice app"
applyTo: "**"
---

# Live Voice Practice - Copilot Instructions

This repository contains:
- `backend/`: Python Flask API + WebSocket voice proxy + scenario/analysis services
- `frontend/`: React + TypeScript + Fluent UI client
- `infra/`: Azure Bicep infrastructure

When generating or modifying code, keep changes focused, minimal, and aligned with existing patterns in the target folder.

## General Guidelines

- Prefer small, scoped changes over large refactors.
- Follow existing naming and module boundaries.
- Keep public behavior and API shapes stable unless explicitly asked to change them.
- Do not introduce new dependencies unless they are clearly required.
- Reuse existing services/hooks/components before creating new ones.

## Azure Dev Environment Targeting

For any Azure-related build, deploy, validation, or test operation in this repository, target this development environment by default:

- Subscription: `9788a92c-2f71-4629-8173-7ad449cb50e1`
- Resource group: `rg-live-voice`
- Full scope: `/subscriptions/9788a92c-2f71-4629-8173-7ad449cb50e1/resourceGroups/rg-live-voice`
- AZD environment name: `live-voice`
- JSON setting: `"azd-env-name": "live-voice"`

When an agent is asked to update the solution and run tests in Azure, it should prefer this environment and avoid creating or switching to a different subscription/resource group unless explicitly requested.

If using AZD, use/select the `live-voice` environment before provisioning/deploying/testing (for example: `azd env select live-voice`).

## AZD Deployment Workflow

For Azure-related application changes in this repository, prefer `azd deploy` as the default deployment path.

- After changing backend, frontend, container configuration, deployment hooks, or app runtime settings that affect the deployed app, prefer running `azd deploy` from the repository root instead of ad-hoc Azure CLI, portal, or one-off container deployment commands.
- Treat `azd deploy` as the expected happy path for incremental application delivery. Use `azd provision` only when infrastructure changes require it, then follow with `azd deploy`. Use `azd up` only when the task explicitly needs the full provision-and-deploy flow.
- Before any AZD deploy/provision operation, select the `live-voice` environment and keep the deploy scoped to the default subscription and resource group unless the user explicitly asks otherwise.
- If `azd deploy` fails, treat that as a blocker to resolve rather than something to work around. Investigate the root cause, fix the relevant code, configuration, script, or environment issue, and rerun `azd deploy`.
- Do not claim Azure work is complete if the intended deployment path is `azd deploy` and it is still broken, unless an external blocker remains that cannot be resolved from the repository or current environment. In that case, report the exact blocker and the next required action.
- When making changes that are meant to be exercised in Azure, prefer validating them with `azd deploy` before finishing whenever credentials and environment access are available.

## Backend (Python) Conventions

Applies to files under `backend/**/*.py`.

- Follow PEP 8 style with project-specific line length of **120**.
- Use type hints on function signatures, especially for new or changed functions.
- Add clear docstrings for new public functions/classes and tests where useful.
- Keep route handlers thin; move non-trivial logic into `backend/src/services/`.
- Reuse constants for endpoint paths, status codes, and repeated messages (as in `backend/src/app.py`).
- Use structured logging via `logging` (avoid ad-hoc `print`).
- Handle exceptions explicitly and return meaningful API error payloads.
- Prefer async-friendly patterns already used by services and handlers.

### Backend Tooling Expectations

- Formatting: `black` (configured in `backend/pyproject.toml`, line length 120)
- Linting: `flake8`, `pylint`, `ruff`
- Type checking: `mypy` (non-strict, use pragmatic typing)
- Testing: `pytest` with tests under `backend/tests/`

Before finishing backend changes, run (from repository root when possible):
- `./scripts/format.sh` (or `cd backend && black . --config pyproject.toml`)
- `./scripts/lint.sh` (or `cd backend && flake8 . --config=.flake8`)
- `cd backend && pytest`

## Frontend (TypeScript/React) Conventions

Applies to files under `frontend/src/**/*.{ts,tsx}`.

- Keep TypeScript `strict` compatibility; avoid weakening compiler settings.
- Prefer functional React components and hooks.
- Place reusable UI in `frontend/src/components/` and shared behavior in `frontend/src/hooks/`.
- Keep API/network logic in `frontend/src/services/`.
- Use Fluent UI tokens/components for styling consistency.
- Avoid `any`; if unavoidable, isolate and narrow quickly.
- Follow existing state patterns (`useState`, `useCallback`) and avoid unnecessary abstractions.

### Frontend Tooling Expectations

- Linting: ESLint (`frontend/eslint.config.js`)
- Formatting: Prettier
- Build/type check: `npm run build`

Before finishing frontend changes:
- `cd frontend && npm run format`
- `cd frontend && npm run lint`
- `cd frontend && npm run build`

## Testing Guidance

- Add or update tests for behavior changes, especially in `backend/tests/unit/`.
- Cover critical paths and common edge cases (invalid payloads, missing fields, error flows).
- Keep tests deterministic and mock external services/network calls.

## API and Contract Safety

- If changing request/response payloads, update both backend and frontend call sites.
- Preserve existing endpoint routes unless explicitly requested.
- Validate user input at API boundaries and return consistent JSON errors.

## Infrastructure Notes

- Infra is Bicep-based under `infra/`; keep infra changes separate from app logic when possible.
- Avoid mixing infrastructure refactors with feature work unless required.

## What to Avoid

- Do not add unrelated refactors in the same change.
- Do not introduce new architecture patterns unless current ones are insufficient.
- Do not hardcode secrets, keys, or environment-specific values.
