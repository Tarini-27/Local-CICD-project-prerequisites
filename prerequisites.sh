#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "======================================"
echo " Installing Prerequisites"
echo "======================================"

echo "Checking required tools..."
for cmd in docker python3 git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd is not installed or not available in PATH."
        exit 1
    fi
done


echo "Checking Docker daemon..."
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running or is unreachable."
    exit 1
fi

echo "Building CI runner image..."
docker build -t runner:v1 .

echo "Installing host-side Python requirements..."
python3 -m venv venv
./venv/bin/python3 -m pip install -r requirements.txt

echo "Configuring Git hook..."
cd task_management_app
if [ ! -f ".githooks/post-commit" ]; then
    echo "ERROR: .githooks/post-commit not found."
    exit 1
fi
chmod +x .githooks/post-commit
git config core.hooksPath .githooks

echo " Setup completed successfully"
echo "Runner image : runner:v1"
echo "Hook path    : $(git config --get core.hooksPath)"
echo "Commit to a branch configured in pipeline.yml to trigger the pipeline"

