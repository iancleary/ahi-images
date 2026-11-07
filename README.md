# ahi-images

Container images for the [`ahi`](https://github.com/iancleary/ahi) CLI. This repo owns
the Containerfiles and the publish flow; the CLI only references the resulting image
(default: `ghcr.io/iancleary/ahi-dev:latest`, overridable via flag or env).

## Images

| Image | Path | Description |
|-------|------|-------------|
| `ghcr.io/iancleary/ahi-dev` | `images/dev/` | Opinionated, minimal dev shell image (base OS + common CLI tools + non-root `dev` user) |

## Usage

```sh
just build   # build ahi-dev:local (timestamps rewritten, matches CI)
just smoke   # build + smoke test (non-root dev, sudo, tools)
just shell   # run and drop into a shell
```

## Publishing

The release pattern is adapted from [`iancleary/dockerfiles`](https://github.com/iancleary/dockerfiles)
(dev-images family): calver releases, multi-arch builds pushed by digest,
supply-chain attestation and signing.

| When | Git tag | Image tags |
| --- | --- | --- |
| Push to `main` that changes a release input | none | `:edge` and `:sha-<7>` |
| Calver release | `ahi-dev-YYYY.MM.DD.NN` | `:YYYY.MM.DD.NN` and `:latest` |

`.github/workflows/publish.yml` runs daily at 15:45 UTC. It releases when no
calver tag exists yet, when the newest tag is at least 30 days old, or when
the tag is at least 3 days old and a release input changed (files under
`images/` and `scripts/`, the root `justfile`, and the build workflows).
Actions → Publish ahi-dev → Run workflow → `release` cuts one without the
age check. `:latest` and the calver tag move only after the multi-arch
manifest succeeded; a failed build does not move them.

Each architecture builds on a native runner (amd64/arm64), is smoke-tested
with the network disabled, pushed by digest, and verified against the smoked
config. Manifest lists are attested with `actions/attest-build-provenance`
and signed with keyless cosign.

```sh
cosign verify ghcr.io/iancleary/ahi-dev:latest \
  --certificate-identity-regexp 'https://github.com/iancleary/ahi-images/.github/workflows/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

GitHub creates the package as private the first time it is pushed. After
the first successful run on `main`, set the package to public and connect
it to this repository if it is not already linked.

## Layout

```
ahi-images/
├── images/
│   └── dev/
│       ├── Containerfile
│       └── entrypoint.sh
├── scripts/            # plan, build, smoke, push, merge, publish
├── justfile
├── .github/workflows/
│   ├── publish.yml
│   └── build-single-image.yml
└── README.md
```
