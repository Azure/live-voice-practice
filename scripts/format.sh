#!/bin/bash

# Format script for both Python and TypeScript code

set -e

echo "[>] Formatting Python code..."

# Run black on backend
echo "Running black on backend..."
cd backend
black . --config pyproject.toml
cd ..

echo "[>] Formatting TypeScript code..."

# Run Prettier on frontend
echo "Running prettier on frontend..."
cd frontend
npx prettier --write "src/**/*.{ts,tsx,js,jsx,json,css,md}"
cd ..

echo "[OK] All code formatted!"