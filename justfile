# Build and publish the ahi-dev image
# Usage: just build | just push | just run | just shell

set shell := ["bash", "-euo", "pipefail", "-c"]

image := "ghcr.io/iancleary/ahi-dev"
tag := `git describe --tags --always --dirty`
full := image + ":" + tag

# default recipe: show available recipes
default:
    @just --list

# build the dev image, tagged :latest and the current git describe
build:
    docker build -f images/dev/Containerfile -t {{ full }} -t {{ image }}:latest images/dev

# push both tags (requires `docker login ghcr.io`)
push: build
    docker push {{ full }}
    docker push {{ image }}:latest

# run the image locally
run *args: build
    docker run --rm -it {{ image }}:latest {{ args }}

# open a shell in the image
shell:
    @just run bash -l
