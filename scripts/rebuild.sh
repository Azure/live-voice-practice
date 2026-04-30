#!/bin/bash

echo "[>] Cleaning previous build..."
rm -rf frontend/static backend/static

cd frontend

echo "[>] Building React app..."
npm run build

echo "[>] Copying build to backend static folder..."
cd ..
mkdir -p backend/static
cp -r frontend/static/* backend/static/

python backend/src/app.py