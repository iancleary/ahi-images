#!/usr/bin/env bash
# Install the pinned uv into /usr/local/bin, then the pinned CPython into
# /opt/python with `uv python install`. Runs as root inside the image build.
# /opt/python ends up owned by dev so uv can manage interpreters later; the
# entrypoint follows that ownership through AHI_DEV_REMAP_PATHS.
set -euo pipefail

here=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
install_directory=/opt/python

read_value() {
  local file=$1 key=$2 line
  line=$(grep -E "^${key}=" "$file" | head -n 1) || true
  if [[ -z "$line" ]]; then
    printf 'missing %s in %s\n' "$key" "$file" >&2
    exit 1
  fi
  printf '%s\n' "${line#*=}"
}

check_https_and_sha() {
  if [[ ! "$1" =~ ^https:// || ! "$2" =~ ^[a-f0-9]{64}$ ]]; then
    printf 'url or sha256 is malformed: %s\n' "$1" >&2
    exit 1
  fi
}

case "$(uname -m)" in
  x86_64)
    suffix=AMD64
    family=x86_64
    ;;
  aarch64)
    suffix=ARM64
    family=aarch64
    ;;
  *)
    printf 'unsupported architecture %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# uv
uv_version=$(read_value "$here/uv.env" UV_VERSION)
uv_url=$(read_value "$here/uv.env" "UV_ARCHIVE_URL_${suffix}")
uv_sha=$(read_value "$here/uv.env" "UV_SHA256_${suffix}")
check_https_and_sha "$uv_url" "$uv_sha"
curl --proto '=https' --tlsv1.2 -fsSL "$uv_url" -o "$work/uv.tar.gz"
printf '%s  %s\n' "$uv_sha" "$work/uv.tar.gz" | sha256sum -c -
mkdir "$work/uv"
tar -xzf "$work/uv.tar.gz" -C "$work/uv" --strip-components=1
install -m 0755 "$work/uv/uv" "$work/uv/uvx" /usr/local/bin/
uv --version | grep -F "uv ${uv_version}" >/dev/null

# CPython through uv, from one recorded archive
version=$(read_value "$here/python.env" PYTHON_VERSION)
standalone_tag=$(read_value "$here/python.env" PYTHON_STANDALONE_TAG)
py_url=$(read_value "$here/python.env" "PYTHON_ARCHIVE_URL_${suffix}")
py_sha=$(read_value "$here/python.env" "PYTHON_SHA256_${suffix}")
check_https_and_sha "$py_url" "$py_sha"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$standalone_tag" =~ ^[0-9]{8}$ ]]; then
  printf 'PYTHON_VERSION or PYTHON_STANDALONE_TAG is malformed\n' >&2
  exit 1
fi
major=${version%%.*}
rest=${version#*.}
minor=${rest%%.*}
patch=${rest#*.}

jq -n \
  --arg key "cpython-${version}-linux-${family}-gnu" \
  --arg url "$py_url" \
  --arg sha256 "$py_sha" \
  --arg build "$standalone_tag" \
  --arg family "$family" \
  --argjson major "$major" \
  --argjson minor "$minor" \
  --argjson patch "$patch" \
  '{
    ($key): {
      name: "cpython",
      arch: {family: $family, variant: null},
      os: "linux",
      libc: "gnu",
      major: $major,
      minor: $minor,
      patch: $patch,
      prerelease: "",
      url: $url,
      sha256: $sha256,
      variant: null,
      build: $build
    }
  }' >"$work/downloads.json"

mkdir -p "$install_directory"
export UV_PYTHON_INSTALL_DIR=$install_directory
export UV_PYTHON_BIN_DIR=$install_directory/bin
export UV_CACHE_DIR=$work/uv-cache
uv python install --no-config --no-cache --default \
  --python-downloads-json-url "$work/downloads.json" "$version"

if [[ ! -x "$install_directory/bin/python3" ]]; then
  printf 'uv did not install python3\n' >&2
  exit 1
fi
if [[ ! -e "$install_directory/bin/python" ]]; then
  ln -s python3 "$install_directory/bin/python"
fi
"$install_directory/bin/python3" --version | grep -F "Python ${version}" >/dev/null
chown -R dev:dev "$install_directory"
