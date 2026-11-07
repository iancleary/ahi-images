#!/usr/bin/env bash
# Install the pinned rustup and Rust toolchain for the dev user.
# Runs as dev inside the image build. RUSTUP_HOME and CARGO_HOME come from
# the Containerfile.
set -euo pipefail

here=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
env_file=$here/rust.env

read_value() {
  local line
  line=$(grep -E "^$1=" "$env_file" | head -n 1) || true
  if [[ -z "$line" ]]; then
    printf 'missing %s in %s\n' "$1" "$env_file" >&2
    exit 1
  fi
  printf '%s\n' "${line#*=}"
}

case "$(uname -m)" in
  x86_64) suffix=AMD64 ;;
  aarch64) suffix=ARM64 ;;
  *)
    printf 'unsupported architecture %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

rust_version=$(read_value RUST_VERSION)
url=$(read_value "RUSTUP_INIT_URL_${suffix}")
sha256=$(read_value "RUSTUP_INIT_SHA256_${suffix}")
if [[ ! "$rust_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'RUST_VERSION must be an exact stable version, got %s\n' "$rust_version" >&2
  exit 1
fi
if [[ ! "$url" =~ ^https:// || ! "$sha256" =~ ^[a-f0-9]{64}$ ]]; then
  printf 'rustup-init url or sha256 is malformed\n' >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$work/rustup-init"
printf '%s  %s\n' "$sha256" "$work/rustup-init" | sha256sum -c -
chmod 0755 "$work/rustup-init"

"$work/rustup-init" -y --no-modify-path --profile minimal \
  --default-toolchain "$rust_version" \
  --component clippy --component rustfmt

export PATH="${CARGO_HOME:?CARGO_HOME is required}/bin:$PATH"
rustc --version | grep -F "rustc ${rust_version}" >/dev/null
cargo clippy --version >/dev/null
rustfmt --version >/dev/null
# The registry cache fills on first use; nothing from the build should remain.
rm -rf "${CARGO_HOME}/registry" "${RUSTUP_HOME:?RUSTUP_HOME is required}/downloads" "${RUSTUP_HOME}/tmp"
