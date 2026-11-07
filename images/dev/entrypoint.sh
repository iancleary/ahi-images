#!/usr/bin/env bash
# ahi-dev entrypoint: exec the given command, default to an interactive shell
set -euo pipefail

echo "ahi-dev shell — user: $(whoami), workdir: $PWD"

if [[ $# -eq 0 ]]; then
    exec bash -l
fi
exec "$@"
