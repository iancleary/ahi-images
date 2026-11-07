#!/usr/bin/env bash
# Build one ahi image: dev, rust, or python (IMAGE_NAME, default dev).
# Local use loads ahi-dev:local, ahi-dev-rust:local, or ahi-dev-python:local.
# Continuous integration loads ahi-images-ci-<name>:smoke and does not push.
# The push script publishes that loaded image by digest after the smoke test.
# rust and python build FROM the base given by AHI_IMAGES_BASE_IMAGE: in CI
# the ghcr.io/iancleary/ahi-dev manifest built in the same run, by digest;
# locally ahi-dev:local by default.
# The docker exporter's unpack option conflicts with rewrite-timestamp, so a
# loaded image is produced by exporting a tarball and loading that tarball.
# Directory entries created by COPY otherwise take the build clock as their
# timestamp, and every layer digest would change on the next build.
set -euo pipefail

script_directory=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -P -- "$script_directory/.." && pwd -P)

known_image_name() {
  case "$1" in
    dev | rust | python) return 0 ;;
  esac
  return 1
}

image_name() {
  local name=${IMAGE_NAME:-dev}
  if ! known_image_name "$name"; then
    printf 'IMAGE_NAME must be dev, rust, or python, got %s\n' "$name" >&2
    exit 2
  fi
  printf '%s\n' "$name"
}

# The published repository name: ahi-dev, ahi-dev-rust, ahi-dev-python.
image_repository_name() {
  local name
  name=$(image_name)
  if [[ "$name" == dev ]]; then
    printf 'ahi-dev\n'
  else
    printf 'ahi-dev-%s\n' "$name"
  fi
}

continuous_integration_local_tag() {
  printf 'ahi-images-ci-%s:smoke\n' "$(image_name)"
}

base_image_reference() {
  local base=${AHI_IMAGES_BASE_IMAGE:-}
  if [[ -z "$base" ]]; then
    base=ahi-dev:local
  fi
  if [[ ! "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]+$ ]]; then
    printf 'base image reference is not usable: %s\n' "$base" >&2
    exit 1
  fi
  printf '%s\n' "$base"
}

current_buildx_driver() {
  local driver
  driver=$(docker buildx inspect 2>/dev/null | awk '/^Driver:/ { print $2; exit }')
  if [[ -z "$driver" ]]; then
    printf 'docker\n'
  else
    printf '%s\n' "$driver"
  fi
}

compose_image_build_command() {
  local name git_sha image_version image_tag base dockerfile build_context
  image_build_command=()
  name=$(image_name)
  dockerfile=$repository_root/images/$name/Containerfile
  build_context=$repository_root/images/$name
  if [[ ! -f "$dockerfile" || ! -d "$build_context" ]]; then
    printf 'missing Containerfile or build context for %s\n' "$name" >&2
    exit 1
  fi
  if [[ -n "${AHI_IMAGES_GIT_SHA:-}" ]]; then
    git_sha=$AHI_IMAGES_GIT_SHA
  elif git_sha=$(git -C "$repository_root" rev-parse HEAD 2>/dev/null); then
    :
  else
    git_sha=unknown
  fi
  image_version=${AHI_IMAGES_IMAGE_VERSION:-local}
  printf 'building %s version=%s revision=%s\n' "$(image_repository_name)" "$image_version" "$git_sha" >&2

  image_build_command=(docker buildx build)
  if [[ -n "${AHI_IMAGES_BUILD_FLAGS:-}" ]]; then
    # Word-splitting is intentional: callers pass a space-separated flag list.
    # shellcheck disable=SC2206
    local extra=(${AHI_IMAGES_BUILD_FLAGS})
    image_build_command+=("${extra[@]}")
  fi
  image_build_command+=(
    --build-arg "GIT_SHA=${git_sha}"
    --build-arg "IMAGE_VERSION=${image_version}"
    --build-arg SOURCE_DATE_EPOCH=0
  )
  if [[ "$name" != dev ]]; then
    base=$(base_image_reference)
    printf 'base image %s\n' "$base" >&2
    image_build_command+=(--build-arg "BASE_IMAGE=${base}")
    if [[ "$base" == *@sha256:* ]]; then
      image_build_command+=(--build-arg "BASE_DIGEST=${base#*@}")
    fi
  fi
  if [[ -z "${AHI_IMAGES_NO_TAG:-}" ]]; then
    image_tag=${IMAGE_TAG:-}
    if [[ -z "$image_tag" ]]; then
      printf 'IMAGE_TAG is required\n' >&2
      exit 1
    fi
    image_build_command+=(-t "$image_tag")
  fi
  image_build_command+=(-f "$dockerfile" "$build_context")
}

run_image_build() {
  compose_image_build_command
  "${image_build_command[@]}"
}

# The docker exporter's unpack option conflicts with rewrite-timestamp, so a
# loaded image is produced by exporting a tarball and loading that tarball.
record_smoked_config_digest() {
  local tar_path=$1 config_name config_digest
  if [[ -z "${RUNNER_TEMP:-}" ]]; then
    return 0
  fi
  config_name=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["Config"])' < <(tar -xOf "$tar_path" manifest.json))
  config_digest=$(tar -xOf "$tar_path" "$config_name" | sha256sum | awk '{print $1}')
  if [[ ! "$config_digest" =~ ^[a-f0-9]{64}$ ]]; then
    printf 'smoked image config digest was not sha256\n' >&2
    return 1
  fi
  printf 'sha256:%s\n' "$config_digest" >"${RUNNER_TEMP}/ahi-images-smoked-config"
}

load_rewritten_image() {
  local tar_path status=0
  tar_path="${TMPDIR:-/tmp}/ahi-image-$$.tar"
  AHI_IMAGES_BUILD_FLAGS="${AHI_IMAGES_BUILD_FLAGS:-} --output type=docker,dest=${tar_path},rewrite-timestamp=true"
  export AHI_IMAGES_BUILD_FLAGS
  run_image_build || status=$?
  if [[ "$status" == 0 ]]; then
    record_smoked_config_digest "$tar_path" || status=$?
  fi
  if [[ "$status" == 0 ]]; then
    docker load --input "$tar_path" >&2 || status=$?
  fi
  rm -f "$tar_path"
  return "$status"
}

require_buildx() {
  if ! docker buildx version >/dev/null 2>&1; then
    printf 'docker buildx is required to build ahi images\n' >&2
    exit 1
  fi
}

continuous_integration_build() {
  : "${PLATFORM:?PLATFORM is required}"
  : "${IMAGE:?IMAGE is required}"
  : "${NO_CACHE:?NO_CACHE is required}"
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  case "$(uname -m):${PLATFORM}" in
    x86_64:linux/amd64 | aarch64:linux/arm64) ;;
    *)
      printf 'runner %s cannot build %s natively\n' "$(uname -m)" "$PLATFORM" >&2
      exit 1
      ;;
  esac
  if [[ "$(image_name)" != dev ]]; then
    : "${AHI_IMAGES_BASE_IMAGE:?AHI_IMAGES_BASE_IMAGE is required for a child image in CI}"
    if [[ "$AHI_IMAGES_BASE_IMAGE" != */*@sha256:* ]]; then
      printf 'CI builds a child image from a registry base by digest, got %s\n' "$AHI_IMAGES_BASE_IMAGE" >&2
      exit 1
    fi
  fi
  local -a flags=(--platform "$PLATFORM" --pull --provenance=false --sbom=false)
  local local_tag
  if [[ "$NO_CACHE" == true ]]; then
    flags+=(--no-cache)
  fi
  local_tag=$(continuous_integration_local_tag)
  export AHI_IMAGES_BUILD_FLAGS="${flags[*]}"
  export IMAGE_TAG=$local_tag
  unset AHI_IMAGES_NO_TAG
  printf 'load %s for %s\n' "$IMAGE_TAG" "$IMAGE" >&2
  load_rewritten_image
  if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    printf 'build did not load %s\n' "$IMAGE_TAG" >&2
    exit 1
  fi
  printf 'smoke=true\n' >>"$GITHUB_OUTPUT"
  printf 'local_tag=%s\n' "$IMAGE_TAG" >>"$GITHUB_OUTPUT"
}

local_build() {
  local tag=$1 platform=$2
  local -a flags=(--provenance=false --sbom=false)
  # --pull would try to fetch a local base tag such as ahi-dev:local from a
  # registry. The base image build already pulled fedora.
  if [[ "$(image_name)" == dev || "$(base_image_reference)" == */* ]]; then
    flags+=(--pull)
  fi
  if [[ -n "$platform" ]]; then
    flags+=(--platform "$platform")
  fi
  export AHI_IMAGES_BUILD_FLAGS="${flags[*]}"
  export IMAGE_TAG=$tag
  unset AHI_IMAGES_NO_TAG
  load_rewritten_image
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  require_buildx
  if [[ -n "${PLATFORM:-}" ]]; then
    continuous_integration_build
    exit 0
  fi
  tag=
  platform=
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        export IMAGE_NAME=$2
        shift 2
        ;;
      --tag)
        tag=$2
        shift 2
        ;;
      --platform)
        platform=$2
        shift 2
        ;;
      *)
        printf 'usage: build_image.sh [--name dev|rust|python] [--tag TAG] [--platform linux/amd64|linux/arm64]\n' >&2
        exit 2
        ;;
    esac
  done
  if [[ -z "$tag" ]]; then
    tag="$(image_repository_name):local"
  fi
  local_build "$tag" "$platform"
fi
