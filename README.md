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
just build   # build images/dev, tagged :latest and git describe
just push    # build + push both tags (requires docker login ghcr.io)
just shell   # run and drop into a shell
```

## Publishing

GitHub Actions (`.github/workflows/publish.yml`) builds and pushes to
`ghcr.io/iancleary/ahi-dev` on pushes to `main` (as `:latest`) and on `v*` tags
(as the semver tag). Release cadence is independent of the ahi CLI.

## Layout

```
ahi-images/
├── images/
│   └── dev/
│       ├── Containerfile
│       └── entrypoint.sh
├── justfile
├── .github/workflows/publish.yml
└── README.md
```
