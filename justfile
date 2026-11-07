# Local ahi-dev image builds. Docker Buildx must already be available.
# CI calls scripts/build_image.sh with PLATFORM set. That path loads
# ahi-images-ci-dev:smoke and does not push.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List recipes.
default:
    @just --list

# Stop when the Docker CLI is missing or the daemon is not already running.
[private]
_require-docker:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v docker >/dev/null 2>&1; then
      printf 'docker is not on PATH. Start Docker yourself, then re-run.\n' >&2
      exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
      printf 'Docker is not running. Start it yourself, then re-run.\n' >&2
      exit 1
    fi
    if ! docker buildx version >/dev/null 2>&1; then
      printf 'docker buildx is required. Install it, then re-run.\n' >&2
      exit 1
    fi

# Build ahi-dev:local (layer timestamps rewritten to the Unix epoch).
build: _require-docker
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/build_image.sh --tag ahi-dev:local

# Build and smoke-test ahi-dev:local.
smoke: build
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/smoke_test_image.sh ahi-dev:local

# Open a shell in the locally built image.
shell: build
    docker run --rm -it ahi-dev:local bash -l
