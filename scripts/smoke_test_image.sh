#!/usr/bin/env bash
# Confirm the ahi-dev account and the installed tools.
# The smoke test disables the network. The account must be dev with
# working passwordless sudo, and every shipped command must run.
set -euo pipefail

usage() {
  printf 'usage: smoke_test_image.sh TAG\n' >&2
  exit 2
}

if [[ $# -ne 1 ]]; then
  usage
fi
tag=$1
if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*:[A-Za-z0-9._-]+$ ]]; then
  printf 'tag is not a usable image reference: %s\n' "$tag" >&2
  exit 2
fi

tools=(git curl wget jq just tmux zsh vim rg fd bat sudo)

run() {
  docker run --rm --network none --entrypoint /usr/bin/env "$tag" "$@"
}

fail=0

user=$(run bash -c 'whoami')
if [[ "$user" != dev ]]; then
  printf 'FAIL: expected user dev, got %s\n' "$user" >&2
  fail=1
fi

uid=$(run bash -c 'id -u')
if [[ "$uid" == 0 ]]; then
  printf 'FAIL: container must not run as root\n' >&2
  fail=1
fi

if ! run sudo -n true >/dev/null 2>&1; then
  printf 'FAIL: passwordless sudo for dev does not work\n' >&2
  fail=1
fi

for tool in "${tools[@]}"; do
  if ! run bash -c "command -v $tool >/dev/null 2>&1"; then
    printf 'FAIL: %s is missing\n' "$tool" >&2
    fail=1
  fi
done

if [[ "$fail" != 0 ]]; then
  printf 'smoke test failed for %s\n' "$tag" >&2
  exit 1
fi

printf 'smoke test passed for %s (user dev, uid %s, %s tools)\n' \
  "$tag" "$uid" "${#tools[@]}"
