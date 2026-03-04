#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Dev Containers on Windows hosts often mount the workspace as root:root.
# Git (>=2.35) may then require marking the repo as a safe.directory.
# Also, if a global ~/.gitconfig contains Windows paths (C:/...), Git on Linux
# will warn "safe.directory ... not absolute". Clean those entries here.
while IFS= read -r safe_dir; do
	if [[ "${safe_dir}" =~ ^[A-Za-z]:/ ]]; then
		git config --global --unset-all safe.directory "${safe_dir}" || true
	fi
done < <(git config --global --get-all safe.directory 2>/dev/null || true)

if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "${repo_root}"; then
	git config --global --add safe.directory "${repo_root}"
fi

cd backend
python3 -m venv .venv
. .venv/bin/activate
pip install --upgrade pip
pip install -r requirements-test.txt
pip install -r requirements.txt
cd ..
echo \\e[32mPython stuff installed.\\e[0m

#cd frontend
#npm install
#cd ..
#echo \\e[32mNode stuff installed.\\e[0m

echo \\e[32mInstallation of dev containers completed successfully.\\e[0m
