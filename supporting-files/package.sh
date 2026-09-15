#!/usr/bin/env bash
# Package the workspace (including the .kiro folder) as a zip — see package.py.
#   bash supporting-files/package.sh [--out dist/SQLMigrationProject.zip] [--include-logs]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec python3 supporting-files/package.py "$@"
