## What changed

<!-- Which image(s), and what moved. -->

## Why

<!-- The reasoning, not just the diff. If this changes a pinned version, say what prompted the
     bump; if it relaxes a test assertion, say why the assertion was wrong rather than the image. -->

## Effect on consumers

<!-- Delete whichever does not apply. -->

- [ ] No change to image contents — rebuild only (tag stays `bookworm-v1`)
- [ ] Contents changed (a tool added or removed) — the version tag needs bumping to `v2`

## Checklist

- [ ] `make check IMAGE=<image>` passes locally, or the PR run is relied on instead
- [ ] `shellcheck ./*/test.sh` is clean
- [ ] New tools are asserted in the image's `test.sh` — `--no-install-recommends` is exactly how
      one silently goes missing
- [ ] Nothing project-specific (dependencies, source, credentials) is baked in
- [ ] For a new image: executable `test.sh`, both `paths:` filters, mirror step, and a Dependabot
      entry — see [Adding another image](../README.md#adding-another-image)

## Verification

<!-- Paste the relevant part of the PR run: the smoke-test output, or the gate result. Note that a
     green run proves both architectures built, tested, and passed the vulnerability and secret
     gates natively. -->
