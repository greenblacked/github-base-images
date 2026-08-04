# 0002 — One `images.json`, one reusable workflow, per-image change detection

**Status:** accepted

## Decision

The image list is a single data file, [.github/images.json](../../.github/images.json), holding
`{image, version, mirror, upstream}` per image. `build-and-push.yml` selects which entries a run
covers (`plan` job) and calls the reusable `build-image.yml` once per selected image from a
matrix. The `lint` job cross-checks `images.json` against the `ci-*` directories in both
directions, including the executable bit on each `test.sh`.

Selection rules: pushes and PRs build only the images whose directories changed; a change to the
pipeline itself (either workflow file, or `images.json`) builds everything; `schedule` and
`workflow_dispatch` always build everything. **Every ambiguous case — force-push, unknown
before-SHA, failed diff, empty selection — falls back to the full list.**

## Why

- At nine images, the previous copy-the-job-pair shape was ~2,950 lines of workflow of which
  ~1,800 were copies differing only in four `env:` values, and adding an image cost ~230 copied
  lines plus edits to two `paths:` lists and the mirror job.
- The shared `paths:` filter meant a one-line fix to one image rebuilt all nine and moved
  `latest` on every one of them.
- The fallback asymmetry is deliberate: over-building costs runner minutes; under-building leaves
  a stale published image that nobody notices until it bites.

## Consequences

- Adding an image is a directory, a JSON entry, and a Dependabot entry — no workflow edits.
- The weekly rebuild is the security-update mechanism and is never narrowed by change detection.
- `version` is per image, which is how `ci-java21` carries `noble-v1` (Temurin publishes no
  Debian tag) while everything else is `bookworm-v1`.
- Called-workflow wiring has two intersection traps recorded in comments where they live:
  caller `env:` does not propagate (the called workflow declares its own), and permissions are
  the intersection of caller-job and called-job declarations.

## Revisit if

GitHub Actions ever supports a per-image matrix *and* per-arch digest fan-out in a single job, or
the image count shrinks to the point where indirection costs more than it saves.
