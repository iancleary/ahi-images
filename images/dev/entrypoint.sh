#!/usr/bin/env bash
# ahi-dev entrypoint. Runs the given command as dev, or a zsh login shell
# when there is none.
#
# When AHI_HOST_UID or AHI_HOST_GID is set, dev's uid and gid are changed to
# match before the command runs, so files written to the bind mount come out
# owned by the host user under rootful Docker on Linux. ahi dev passes both
# from the owner of the mounted directory. Unset, nothing changes.
#
# The image runs as dev. A remap needs root, so the script re-executes itself
# through sudo, remaps, then drops back to dev with setpriv. Directories that
# must follow the remap are the home directory and any colon-separated paths
# in AHI_DEV_REMAP_PATHS (set by child images for toolchains outside home).
set -euo pipefail

dev_home=/home/dev

fail() {
  printf 'ahi-dev entrypoint: %s\n' "$1" >&2
  exit 1
}

run_as_dev() {
  if [[ $# -eq 0 ]]; then
    if [[ -t 2 ]]; then
      printf 'ahi-dev shell: user dev, workdir %s\n' "$PWD" >&2
    fi
    set -- zsh -l
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    exec setpriv --reuid=dev --regid=dev --init-groups \
      env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND -u SUDO_HOME -- \
      HOME="$dev_home" USER=dev LOGNAME=dev "$@"
  fi
  exec "$@"
}

if [[ -z "${AHI_HOST_UID:-}" && -z "${AHI_HOST_GID:-}" ]]; then
  run_as_dev "$@"
fi

current_uid=$(id -u dev)
current_gid=$(id -g dev)
target_uid=${AHI_HOST_UID:-$current_uid}
target_gid=${AHI_HOST_GID:-$current_gid}

if [[ ! "$target_uid" =~ ^[0-9]+$ || ! "$target_gid" =~ ^[0-9]+$ ]]; then
  fail "AHI_HOST_UID and AHI_HOST_GID must be non-negative integers"
fi
if [[ "$target_uid" -eq 0 || "$target_gid" -eq 0 ]]; then
  printf 'ahi-dev entrypoint: host user is root; dev keeps uid %s gid %s\n' \
    "$current_uid" "$current_gid" >&2
  run_as_dev "$@"
fi
if [[ "$target_uid" -eq "$current_uid" && "$target_gid" -eq "$current_gid" ]]; then
  run_as_dev "$@"
fi

if [[ "$(id -u)" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    fail "sudo is required to remap dev to uid ${target_uid} gid ${target_gid}"
  fi
  # sudo replaces PATH with secure_path; env restores the image's PATH.
  exec sudo -n -E -- env PATH="$PATH" "$0" "$@"
fi

if [[ "$target_gid" -ne "$current_gid" ]]; then
  groupmod --non-unique --gid "$target_gid" dev
fi
if [[ "$target_uid" -ne "$current_uid" ]]; then
  # usermod re-owns the home directory's files by uid only; the chown below
  # also applies the gid change and covers the extra paths.
  usermod --non-unique --uid "$target_uid" dev
fi

remap_paths=("$dev_home")
if [[ -n "${AHI_DEV_REMAP_PATHS:-}" ]]; then
  IFS=: read -r -a extra_paths <<<"$AHI_DEV_REMAP_PATHS"
  remap_paths+=("${extra_paths[@]}")
fi
for path in "${remap_paths[@]}"; do
  if [[ -n "$path" && -e "$path" ]]; then
    chown -R -h "${target_uid}:${target_gid}" "$path"
  fi
done

run_as_dev "$@"
