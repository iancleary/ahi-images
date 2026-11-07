#!/usr/bin/env bash
# Confirm one ahi image: the dev account, the entrypoint, the uid remap, and
# the installed tools. The network is disabled for every run.
#
#   smoke_test_image.sh [--name dev|rust|python] TAG
#
# Every image: the command runs as dev (not root), passwordless sudo works,
# zsh starts with powerlevel10k and gitstatusd without the network,
# the entrypoint passes argv and stdout through untouched, and
# AHI_HOST_UID/AHI_HOST_GID remap dev and the files it writes.
# rust: cargo, clippy, rustfmt at the recorded version, gcc present,
# CARGO_TARGET_DIR set, and an offline hello-world build links.
# python: uv and python3 at the recorded versions, /opt/python owned by dev.
set -euo pipefail

script_directory=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -P -- "$script_directory/.." && pwd -P)

usage() {
  printf 'usage: smoke_test_image.sh [--name dev|rust|python] TAG\n' >&2
  exit 2
}

name=${IMAGE_NAME:-dev}
tag=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      name=$2
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      if [[ -n "$tag" ]]; then
        usage
      fi
      tag=$1
      shift
      ;;
  esac
done
if [[ -z "$tag" ]]; then
  usage
fi
case "$name" in
  dev | rust | python) ;;
  *) usage ;;
esac
if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*:[A-Za-z0-9._-]+$ ]]; then
  printf 'tag is not a usable image reference: %s\n' "$tag" >&2
  exit 2
fi

read_value() {
  local file=$1 key=$2 line
  line=$(grep -E "^${key}=" "$file" | head -n 1) || true
  printf '%s\n' "${line#*=}"
}

base_tools=(git curl wget jq just tmux zsh vim rg fd bat sudo setpriv usermod groupmod)

# Bypass the entrypoint: checks on the image's static account.
run() {
  docker run --rm --network none --entrypoint /usr/bin/env "$tag" "$@"
}
# Through the entrypoint, as ahi dev runs it.
run_entry() {
  docker run --rm --network none "$@"
}

fail=0
failed() {
  printf 'FAIL: %s\n' "$1" >&2
  fail=1
}

user=$(run bash -c 'whoami')
if [[ "$user" != dev ]]; then
  failed "expected user dev, got $user"
fi
uid=$(run bash -c 'id -u')
if [[ "$uid" == 0 ]]; then
  failed "container must not run as root"
fi
if ! run sudo -n true >/dev/null 2>&1; then
  failed "passwordless sudo for dev does not work"
fi
for tool in "${base_tools[@]}"; do
  if ! run bash -c "command -v $tool >/dev/null 2>&1"; then
    failed "$tool is missing"
  fi
done

# Entrypoint without a remap: still dev, argv and stdout untouched.
out=$(run_entry "$tag" printf '%s %s' hello 'two words' || true)
if [[ "$out" != "hello two words" ]]; then
  failed "entrypoint changed argv or stdout: '$out'"
fi
ids=$(run_entry "$tag" bash -c 'printf "%s %s" "$(id -un)" "$(id -u)"' || true)
if [[ "$ids" != "dev $uid" ]]; then
  failed "entrypoint without remap ran as '$ids', want 'dev $uid'"
fi
code=0
run_entry "$tag" bash -c 'exit 7' || code=$?
if [[ "$code" != 7 ]]; then
  failed "entrypoint did not propagate exit code 7, got $code"
fi
if [[ "$(run_entry --workdir /work "$tag" pwd)" != /work ]]; then
  failed "/work is not usable as a working directory"
fi

# Entrypoint with a remap: dev takes the host ids, home and written files follow.
remap=$(run_entry -e AHI_HOST_UID=4242 -e AHI_HOST_GID=4343 --tmpfs /work:uid=4242,gid=4343 \
  --workdir /work "$tag" \
  bash -c 'touch /work/f && printf "%s %s %s %s %s %s" "$(id -un)" "$(id -u)" "$(id -g)" "$HOME" "$(stat -c %u:%g "$HOME")" "$(stat -c %u:%g /work/f)"' || true)
if [[ "$remap" != "dev 4242 4343 /home/dev 4242:4343 4242:4343" ]]; then
  failed "uid remap produced '$remap'"
fi
if ! run_entry -e AHI_HOST_UID=4242 -e AHI_HOST_GID=4343 "$tag" sudo -n true >/dev/null 2>&1; then
  failed "passwordless sudo stops working after the remap"
fi
same=$(run_entry -e AHI_HOST_UID="$uid" -e AHI_HOST_GID="$(run bash -c 'id -g')" "$tag" id -u || true)
if [[ "$same" != "$uid" ]]; then
  failed "remap to the current ids changed the uid to $same"
fi
root_case=$(run_entry -e AHI_HOST_UID=0 -e AHI_HOST_GID=0 "$tag" id -u 2>/dev/null || true)
if [[ "$root_case" != "$uid" ]]; then
  failed "a root host user must leave dev at uid $uid, got $root_case"
fi
if run_entry -e AHI_HOST_UID=abc "$tag" true >/dev/null 2>&1; then
  failed "a non-numeric AHI_HOST_UID must be refused"
fi

# zsh with powerlevel10k, offline: the theme loads, the wizard stays off,
# gitstatusd is already present, and git status shows in a repository.
p10k=$(run_entry "$tag" zsh -ilc 'typeset -f prompt_powerlevel9k_setup >/dev/null && (( ${+functions[p10k]} )) && ls ~/.cache/gitstatus/gitstatusd-* >/dev/null && printf ok' 2>/dev/null || true)
if [[ "$p10k" != ok ]]; then
  failed "zsh did not load powerlevel10k with a prefetched gitstatusd ('$p10k')"
fi
if run_entry "$tag" zsh -ilc 'true' 2>&1 | grep -qi 'wizard\|gitstatus.*download'; then
  failed "zsh startup tried the wizard or a gitstatusd download"
fi
# gitstatusd needs job control, so this probe runs with a pseudo-tty.
gitstatus=$(run_entry -t "$tag" zsh -ilc 'source ~/.local/share/powerlevel10k/gitstatus/gitstatus.plugin.zsh && cd /tmp && git init -q r && cd r && git -c user.name=a -c user.email=a@b commit -q --allow-empty -m x && gitstatus_start -s -1 -u -1 -d -1 -c -1 -m -1 P && gitstatus_query P && printf "result=%s" "$VCS_STATUS_RESULT"' 2>/dev/null | tr -d '\r' || true)
if [[ "$gitstatus" != *result=ok-sync* ]]; then
  failed "gitstatusd does not report a repository ('$gitstatus')"
fi

case "$name" in
  rust)
    rust_version=$(read_value "$repository_root/images/rust/rust.env" RUST_VERSION)
    for probe in "rustc --version" "cargo --version" "cargo clippy --version" "rustfmt --version"; do
      if ! run_entry "$tag" bash -c "$probe" >/dev/null 2>&1; then
        failed "$probe does not run"
      fi
    done
    if ! run_entry "$tag" rustc --version | grep -Fq "rustc ${rust_version}"; then
      failed "rustc is not ${rust_version}"
    fi
    if ! run_entry "$tag" bash -c 'command -v gcc' >/dev/null 2>&1; then
      failed "gcc is missing"
    fi
    if [[ "$(run_entry "$tag" bash -c 'printf %s "$CARGO_TARGET_DIR"')" != /work/target/dev ]]; then
      failed "CARGO_TARGET_DIR is not /work/target/dev"
    fi
    if ! run_entry "$tag" bash -c 'cd /tmp && cargo new --quiet hello && cd hello && CARGO_TARGET_DIR=/tmp/target cargo run --quiet' | grep -Fq 'Hello, world!'; then
      failed "offline hello-world cargo build did not run"
    fi
    if ! run_entry -e AHI_HOST_UID=4242 -e AHI_HOST_GID=4343 "$tag" bash -c 'test "$(stat -c %u "$RUSTUP_HOME")" = 4242 && cargo --version' >/dev/null 2>&1; then
      failed "the Rust toolchain did not follow the uid remap"
    fi
    ;;
  python)
    python_version=$(read_value "$repository_root/images/python/python.env" PYTHON_VERSION)
    uv_version=$(read_value "$repository_root/images/python/uv.env" UV_VERSION)
    if ! run_entry "$tag" python3 --version | grep -Fq "Python ${python_version}"; then
      failed "python3 is not ${python_version}"
    fi
    if ! run_entry "$tag" python --version | grep -Fq "Python ${python_version}"; then
      failed "python is not ${python_version}"
    fi
    if ! run_entry "$tag" uv --version | grep -Fq "uv ${uv_version}"; then
      failed "uv is not ${uv_version}"
    fi
    if ! run_entry "$tag" python3 -c 'import ssl, sqlite3, zlib' >/dev/null 2>&1; then
      failed "python3 standard library modules do not import"
    fi
    if ! run_entry "$tag" bash -c 'uv python find --no-config 3.14' >/dev/null 2>&1; then
      failed "uv does not find the managed interpreter"
    fi
    if [[ "$(run_entry "$tag" stat -c %U /opt/python)" != dev ]]; then
      failed "/opt/python is not owned by dev"
    fi
    if [[ "$(run_entry -e AHI_HOST_UID=4242 -e AHI_HOST_GID=4343 "$tag" stat -c %u:%g /opt/python)" != 4242:4343 ]]; then
      failed "/opt/python did not follow the uid remap"
    fi
    ;;
esac

if [[ "$fail" != 0 ]]; then
  printf 'smoke test failed for %s (%s)\n' "$tag" "$name" >&2
  exit 1
fi

printf 'smoke test passed for %s (%s image, user dev, uid %s)\n' "$tag" "$name" "$uid"
