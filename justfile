# Local ahi image builds: dev, rust, python. Docker Buildx must already be
# available, with the default docker driver so a child image can build FROM
# the ahi-dev:local tag in the engine's image store.
# CI calls scripts/build_image.sh with PLATFORM set. That path loads
# ahi-images-ci-<name>:smoke and does not push.

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

# Build one image as ahi-dev[-NAME]:local. rust and python build ahi-dev:local first.
build name="dev": _require-docker
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "{{name}}" != dev ]]; then
      bash scripts/build_image.sh --name dev
    fi
    bash scripts/build_image.sh --name "{{name}}"

# Build and smoke-test one image.
smoke name="dev": (build name)
    #!/usr/bin/env bash
    set -euo pipefail
    tag=ahi-dev:local
    if [[ "{{name}}" != dev ]]; then
      tag="ahi-dev-{{name}}:local"
    fi
    bash scripts/smoke_test_image.sh --name "{{name}}" "$tag"

# Build and smoke-test all three images.
smoke-all: (smoke "dev") (smoke "rust") (smoke "python")

# Open a shell in a locally built image.
shell name="dev": (build name)
    #!/usr/bin/env bash
    set -euo pipefail
    tag=ahi-dev:local
    if [[ "{{name}}" != dev ]]; then
      tag="ahi-dev-{{name}}:local"
    fi
    docker run --rm -it --volume "$PWD:/work" --workdir /work \
      -e AHI_HOST_UID="$(id -u)" -e AHI_HOST_GID="$(id -g)" "$tag" bash -l
