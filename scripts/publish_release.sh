#!/usr/bin/env bash
# Tag ahi-dev, ahi-dev-rust, and ahi-dev-python with the calver and :latest,
# then create the git release. The release job calls this only after every
# manifest succeeded. Each digest is still checked first, and no image is
# tagged when any digest is missing, so the three move together.
set -euo pipefail

: "${GIT_TAG:?GIT_TAG is required}"
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${DIGEST_AHI_DEV:?DIGEST_AHI_DEV is required}"
: "${DIGEST_AHI_DEV_RUST:?DIGEST_AHI_DEV_RUST is required}"
: "${DIGEST_AHI_DEV_PYTHON:?DIGEST_AHI_DEV_PYTHON is required}"

if [[ ! "$GIT_TAG" =~ ^ahi-dev-[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}$ ]]; then
  printf 'refusing to create tag %s\n' "$GIT_TAG" >&2
  exit 1
fi
if [[ "$GIT_TAG" != "ahi-dev-${IMAGE_VERSION}" ]]; then
  printf 'git tag %s does not match image version %s\n' "$GIT_TAG" "$IMAGE_VERSION" >&2
  exit 1
fi
if [[ ! "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'GITHUB_SHA must be 40 lowercase hex characters\n' >&2
  exit 1
fi

images=(ahi-dev ahi-dev-rust ahi-dev-python)
digests=("$DIGEST_AHI_DEV" "$DIGEST_AHI_DEV_RUST" "$DIGEST_AHI_DEV_PYTHON")
for index in "${!images[@]}"; do
  if [[ ! "${digests[$index]}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    printf 'refusing to tag any image; missing digest for %s\n' "${images[$index]}" >&2
    exit 1
  fi
done

if [[ -n "${AHI_IMAGES_RELEASE_PRINT:-}" ]]; then
  for index in "${!images[@]}"; do
    image=ghcr.io/iancleary/${images[$index]}
    printf '%s\n' -t "${image}:${IMAGE_VERSION}" -t "${image}:latest" "${image}@${digests[$index]}"
  done
  printf 'git_tag=%s\n' "$GIT_TAG"
  exit 0
fi

for index in "${!images[@]}"; do
  image=ghcr.io/iancleary/${images[$index]}
  docker buildx imagetools create \
    -t "${image}:${IMAGE_VERSION}" \
    -t "${image}:latest" \
    "${image}@${digests[$index]}"
done

git fetch --tags origin
if git rev-parse -q --verify "refs/tags/${GIT_TAG}^{}" >/dev/null; then
  existing=$(git rev-parse "refs/tags/${GIT_TAG}^{}")
  if [[ "$existing" != "$GITHUB_SHA" ]]; then
    printf 'tag %s already points at %s\n' "$GIT_TAG" "$existing" >&2
    exit 1
  fi
  printf 'tag %s already exists on this commit\n' "$GIT_TAG"
  exit 0
fi

notes=$(
  cat <<EOF2
ahi-dev ${IMAGE_VERSION}.

Multi-arch (linux/amd64, linux/arm64) manifest lists, each also tagged :latest:

- ghcr.io/iancleary/ahi-dev:${IMAGE_VERSION}
- ghcr.io/iancleary/ahi-dev-rust:${IMAGE_VERSION}
- ghcr.io/iancleary/ahi-dev-python:${IMAGE_VERSION}

:edge is unchanged by this release.

Commit: ${GITHUB_SHA}
EOF2
)

gh release create "$GIT_TAG" --title "$GIT_TAG" --notes "$notes" --target "$GITHUB_SHA"
