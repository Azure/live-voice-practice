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
