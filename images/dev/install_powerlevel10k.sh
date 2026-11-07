#!/usr/bin/env bash
# Install powerlevel10k for the dev user at the pinned commit, prefetch
# gitstatusd so the prompt works offline, and put the lean preset in place
# so the first zsh does not start the configuration wizard.
# Runs as dev inside the image build.
set -euo pipefail

here=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
env_file=$here/powerlevel10k.env
home=${HOME:?HOME is required}
theme_directory=$home/.local/share/powerlevel10k

read_value() {
  local line
  line=$(grep -E "^$1=" "$env_file" | head -n 1) || true
  if [[ -z "$line" ]]; then
    printf 'missing %s in %s\n' "$1" "$env_file" >&2
    exit 1
  fi
  printf '%s\n' "${line#*=}"
}

commit=$(read_value P10K_COMMIT)
repository=$(read_value P10K_REPOSITORY)
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ || ! "$repository" =~ ^https:// ]]; then
  printf 'P10K_COMMIT or P10K_REPOSITORY is malformed\n' >&2
  exit 1
fi

mkdir -p "$theme_directory"
git -C "$theme_directory" init -q
git -C "$theme_directory" fetch -q --depth 1 "$repository" "$commit"
git -C "$theme_directory" checkout -q --detach FETCH_HEAD
if [[ "$(git -C "$theme_directory" rev-parse HEAD)" != "$commit" ]]; then
  printf 'checked out commit does not match the pin\n' >&2
  exit 1
fi
rm -rf "$theme_directory/.git"

# gitstatusd lands in ~/.cache/gitstatus. The installer checks its sha256.
GITSTATUS_CACHE_DIR=$home/.cache/gitstatus "$theme_directory/gitstatus/install"
if ! compgen -G "$home/.cache/gitstatus/gitstatusd-*" >/dev/null; then
  printf 'gitstatusd was not installed\n' >&2
  exit 1
fi

cp "$theme_directory/config/p10k-lean.zsh" "$home/.p10k.zsh"
# Put the ahi_dev segment (user@image:version project) first on line one.
if ! grep -qE '^    dir +# current directory$' "$home/.p10k.zsh"; then
  printf 'p10k-lean.zsh layout changed; the ahi_dev segment insertion needs updating\n' >&2
  exit 1
fi
sed -i -E 's/^(    )dir( +# current directory)$/\1ahi_dev                 # user@image:version project\n\1dir\2/' "$home/.p10k.zsh"
cat "$here/p10k-ahi-dev.zsh" >>"$home/.p10k.zsh"
install -m 0644 "$here/zshrc" "$home/.zshrc"
