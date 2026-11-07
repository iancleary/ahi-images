# ahi-images

Container images for the [`ahi`](https://github.com/iancleary/ahi) CLI. This repo owns
the Containerfiles and the publish flow; the CLI only references the resulting image
(default: `ghcr.io/iancleary/ahi-dev:latest`, overridable via flag, env, or
`ahi.dev.yaml`). Design context for `ahi dev` and `ahi dev run` lives in
[docs/DEV_CONTAINER.md](https://github.com/iancleary/ahi/blob/main/docs/DEV_CONTAINER.md)
in the ahi repository.

## Images

One minimal base, with toolchains layered on top. A repository picks the layer
it wants; the base stays small, and Node is deliberately absent.

| Image | Path | Adds |
|-------|------|------|
| `ghcr.io/iancleary/ahi-dev` | `images/dev/` | Fedora, common CLI tools, zsh with powerlevel10k, non-root `dev` user with passwordless sudo, the remapping entrypoint |
| `ghcr.io/iancleary/ahi-dev-rust` | `images/rust/` | rustup with a pinned stable toolchain, clippy, rustfmt, gcc; `CARGO_TARGET_DIR=/work/target/dev` |
| `ghcr.io/iancleary/ahi-dev-python` | `images/python/` | uv at a pinned version, one pinned CPython 3.14 in `/opt/python` |

`ahi-dev-rust` and `ahi-dev-python` are built `FROM` the `ahi-dev` manifest produced
in the same publish run, by digest, so the three images of one tag share the same base.

Pick a layer in the repository's `ahi.dev.yaml`:

```yaml
image: ghcr.io/iancleary/ahi-dev-rust:latest
```

### Pinned versions

Installer versions are recorded in `.env` files beside each Containerfile and verified
with sha256 before use, so two contributors on `:latest` get the same shell.

| File | Pins |
|------|------|
| `images/dev/powerlevel10k.env` | `P10K_COMMIT`, the powerlevel10k commit git checks out (content-addressed); its installer fetches gitstatusd and checks the sha256 it records |
| `images/rust/rust.env` | `RUST_VERSION` (installed through rustup, which verifies components against the signed channel manifest) and `RUSTUP_VERSION` with the `rustup-init` sha256 per architecture |
| `images/python/uv.env` | `UV_VERSION` with the release archive sha256 per architecture |
| `images/python/python.env` | `PYTHON_VERSION` and the python-build-standalone archive sha256 per architecture; uv checks it before unpacking |

Bump a pin by editing the `.env` file. The smoke test checks the installed version
against the recorded one.

### zsh and powerlevel10k

The base image ships zsh with [powerlevel10k](https://github.com/romkatv/powerlevel10k)
under `/home/dev/.local/share/powerlevel10k`, the lean preset as `~/.p10k.zsh`, and
gitstatusd prefetched into `~/.cache/gitstatus` so the prompt works offline. The
configuration wizard is disabled; edit `~/.p10k.zsh` or run `p10k configure`. The lean
preset expects a Nerd Font in the terminal. bash remains the login shell;
`ahi dev --shell zsh` opens zsh.

### Working directory and `target/`

`ahi dev` bind-mounts the working directory read-write at `/work` and nothing else.
The Rust image sets `CARGO_TARGET_DIR=/work/target/dev`, so builds inside the
container write to a subdirectory of the repository's `target/` and do not invalidate
the host toolchain's cache (or vice versa). `/work` exists in the image, owned by `dev`,
so the images also work without a mount.

### File ownership: uid remapping

Rootful Docker on Linux writes files from the container as the image's `dev` user
(uid 1000). Docker Desktop and rootless podman already map ownership to the host user.

When `AHI_HOST_UID` and `AHI_HOST_GID` are set, the entrypoint changes `dev`'s uid and
gid to match before running the command, re-owns `/home/dev` and any paths listed in
`AHI_DEV_REMAP_PATHS` (the Python image lists `/opt/python`; the Rust toolchain lives
under `/home/dev`), and drops back to `dev` with `setpriv`. `ahi dev` and `ahi dev run`
pass both variables from the owner of the mounted directory. Unset, nothing changes.
A host uid or gid of 0 is ignored, and a non-numeric value is refused.

```sh
docker run --rm -it -v "$PWD:/work" -w /work \
  -e AHI_HOST_UID="$(id -u)" -e AHI_HOST_GID="$(id -g)" \
  ghcr.io/iancleary/ahi-dev-rust:latest cargo test
```

The entrypoint passes argv and stdout through untouched and returns the command's
exit code, so `ahi dev run -- <command>` can be scripted. The one-line banner is
written to stderr only when there is no command and stderr is a terminal.

## Usage

```sh
just build            # ahi-dev:local (timestamps rewritten, matches CI)
just build rust       # ahi-dev:local, then ahi-dev-rust:local FROM it
just smoke python     # build + smoke test (account, entrypoint, remap, tools)
just smoke-all        # all three
just shell rust       # mount $PWD at /work with the uid remap and open a shell
```

Local child builds need the default `docker` buildx driver, which can read
`ahi-dev:local` from the engine's image store.

## Publishing

The release pattern is adapted from [`iancleary/dockerfiles`](https://github.com/iancleary/dockerfiles)
(dev-images family): calver releases, multi-arch builds pushed by digest,
supply-chain attestation and signing. The three images are one release train.

| When | Git tag | Image tags (each image) |
| --- | --- | --- |
| Push to `main` that changes a release input | none | `:edge` and `:sha-<7>` |
| Calver release | `ahi-dev-YYYY.MM.DD.NN` | `:YYYY.MM.DD.NN` and `:latest` |

`.github/workflows/publish.yml` runs daily at 15:45 UTC. It releases when no
calver tag exists yet, when the newest tag is at least 30 days old, or when
the tag is at least 3 days old and a release input changed (files under
`images/` and `scripts/`, the root `justfile`, and the build workflows).
Actions → Publish ahi-dev images → Run workflow → `release` cuts one without the
age check. `:latest` and the calver tags move only after all three multi-arch
manifests succeeded; a failed build moves none of them.

Each architecture builds on a native runner (amd64/arm64), is smoke-tested
with the network disabled, pushed by digest, and verified against the smoked
config. `ahi-dev` builds first; `ahi-dev-rust` and `ahi-dev-python` then build
`FROM ghcr.io/iancleary/ahi-dev@<digest>` of that run. Manifest lists are
attested with `actions/attest-build-provenance` and signed with keyless cosign.

```sh
cosign verify ghcr.io/iancleary/ahi-dev-rust:latest \
  --certificate-identity-regexp 'https://github.com/iancleary/ahi-images/.github/workflows/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

GitHub creates each package as private the first time it is pushed. After
the first successful run on `main`, set `ahi-dev`, `ahi-dev-rust`, and
`ahi-dev-python` to public and connect them to this repository if they are not
already linked. The child builds pull `ahi-dev` by digest with the workflow token,
so they work while the package is still private.

## Layout

```
ahi-images/
├── images/
│   ├── dev/
│   │   ├── Containerfile
│   │   ├── entrypoint.sh       # runs as dev; AHI_HOST_UID/GID remap
│   │   ├── install_powerlevel10k.sh
│   │   ├── powerlevel10k.env   # pinned commit
│   │   └── zshrc
│   ├── rust/
│   │   ├── Containerfile       # FROM ${BASE_IMAGE}
│   │   ├── install_rust.sh
│   │   └── rust.env            # pinned rustup and Rust versions
│   └── python/
│       ├── Containerfile       # FROM ${BASE_IMAGE}
│       ├── install_python.sh
│       ├── uv.env              # pinned uv
│       └── python.env          # pinned CPython
├── scripts/            # plan, build, smoke, push, merge, publish
├── justfile
├── .github/workflows/
│   ├── publish.yml             # plan → dev → rust, python → release
│   └── build-single-image.yml  # one image, both architectures
└── README.md
```
