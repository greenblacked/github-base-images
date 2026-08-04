# 0001 — Mirror upstream base images into GHCR

**Status:** accepted

## Decision

Every image builds `FROM` a copy of its upstream base mirrored into
`ghcr.io/greenblacked/mirror-*`, refreshed by the `mirror` job on every publish run.
`docker buildx imagetools create` performs the copy registry-to-registry, preserving the
multi-arch manifest list. Each `Dockerfile.ci` keeps its `ARG BASE_IMAGE` **defaulting to the
real upstream ref** — CI overrides it with the mirror on `main` only.

## Why

- **Availability and rate limits.** Publish runs must not depend on Docker Hub being up or on its
  anonymous pull quota from shared runner IPs. (MCR, used by `ci-dotnet9`, has no such limits —
  it is mirrored anyway so builds depend on one registry rather than two.)
- **Digest control.** The mirror fixes the exact base digest a publish builds from, instead of
  whatever upstream's mutable tag points at mid-run.
- **The upstream default is load-bearing twice.** Local builds and PR builds work with no
  `ghcr.io` login, and Dependabot reads that default to propose base bumps — pointing it at the
  mirror would break both.

## Consequences

- PR runs never touch mirrors: validation cannot mutate registry state, and a brand-new image's
  first PR needs no existing mirror.
- A `docker pull/tag/push` mirror would flatten the manifest list to one architecture —
  `imagetools create` is not an implementation detail but the reason multi-arch survives.
- Each `mirror-*` package must be made public once, by hand, after first publish — `GITHUB_TOKEN`
  cannot change package visibility.

## Revisit if

GHCR gains upstream pull-through caching with digest pinning, or the repo stops publishing from
shared runners.
