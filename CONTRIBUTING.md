# Contributing

## The short version

CI is the source of truth. Open a pull request and the full pipeline runs — lint, build on both
architectures on native runners, smoke test, three Trivy scans, and both gates — with every
registry write skipped. A green PR run is the pre-merge proof.

## Local loop

You do not need to authenticate to `ghcr.io` to build anything here. PR builds and local builds
both use the upstream base directly, via each Dockerfile's `ARG BASE_IMAGE` default.

```bash
make list                     # images, discovered by globbing */Dockerfile.ci
make check IMAGE=ci-rust185   # build, then smoke-test
make check-all                # every image
```

`make check` reproduces the build-and-smoke-test part of a PR run. It does **not** run the Trivy
scans or the vulnerability and secret gates — those stay CI's job, and they can fail a change that
passed locally.

Requires GNU make and a working Docker daemon. `PLATFORM=linux/amd64` cross-builds under emulation;
`TAG=` overrides the local `:test` tag.

## Before opening a PR

The `lint` job runs these first, so running them locally saves a round trip:

```bash
shellcheck ./*/test.sh
hadolint */Dockerfile.ci      # DL3008 and DL3006 are ignored inline, deliberately
actionlint                    # workflows
```

## Adding an image

The README's [Adding another image](README.md#adding-another-image) section is the authoritative
checklist. In short: a `Dockerfile.ci` and an **executable** `test.sh`, a copied `build`/`merge`
job pair with only its `env:` block changed, both `paths:` filters, a mirror step, and a Dockerfile
entry in `.github/dependabot.yml`.

Two rules that are easy to miss:

- **`chmod +x` the test script.** Both CI and `make test` execute it directly.
- **Scope the build cache per image and architecture** (`scope: <image>-<arch>`), or builds evict
  each other's layers.

## What does not belong in an image

Project dependencies, application source, credentials, and project-specific build tools. Each
`test.sh` asserts their absence, and those assertions are the point — if you find yourself relaxing
one to make a build pass, that is usually the bug rather than the test.

Pinned tool versions (Terraform, kubectl, AWS CLI, Docker client in `ci-tools`) are `ARG`s so a
bump is a one-line change that CI revalidates. Note that Dependabot does **not** track these — it
only updates each Dockerfile's `ARG BASE_IMAGE` — so they move when a human moves them.

## Commit and PR conventions

Explain *why* in the commit body, not just what. This repository's comments and history lean
heavily on recording the reasoning behind a constraint, because most of the surprising decisions
here (why browsers are not baked in, why library vulnerabilities do not gate, why builds are native
rather than QEMU) are non-obvious and get re-litigated otherwise.
