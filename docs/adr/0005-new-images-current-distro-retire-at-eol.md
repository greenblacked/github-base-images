# 0005 — New images start on the current distro; images retire at upstream end of support

**Status:** accepted

## Decision

Two rules for an image's lifecycle, set when `ci-dotnet10`, `ci-java25`, `ci-python314`, `ci-php85`
and `ci-ruby40` were added:

- **A brand-new image starts on its upstream's current stable distribution**, not on whatever
  the existing images happen to use. That means Debian Trixie (`trixie-v1`), or Ubuntu Noble
  (`noble-v1`) where the upstream publishes no Debian image at all — .NET 10 on MCR and Temurin.
  Existing images are **not** migrated by this decision; each carries its own `version` line and
  moves on its own schedule.
- **An image is retired on its upstream runtime's end-of-support date**, rather than rebuilt
  indefinitely. `ci-dotnet8` and `ci-dotnet9` are the first: .NET 8 and .NET 9 both reach end of
  support on 2026-11-10, and both images are retired after it, with `ci-dotnet10` as the
  successor. Retiring means removing the image from `images.json` and its directory. Deleting the
  published GHCR package is a separate decision for the repository owner.

## Why

- **Starting on Bookworm would be migration debt on day one.** Debian 12's regular security
  support has ended and it is on reduced Debian LTS coverage. Matching the existing `bookworm-v1`
  line would buy uniformity for a few months, then force a tag bump on consumers who only just
  adopted the image. The `version` field is per image ([0002](0002-images-json-reusable-workflow.md)),
  so mixing distributions costs nothing structurally.
- **Noble, not a hand-installed runtime on Debian.** Where upstream ships no Debian image,
  installing the runtime onto Debian would replace an official, upstream-maintained build with one
  this repository has to maintain. The Java images already made that trade; .NET 10 now does too.
- **A rebuild does not patch a dead runtime.** The weekly rebuild refreshes the OS layer. Once
  the runtime itself stops receiving fixes, each rebuild publishes a fresh digest of an unpatched
  SDK. That looks maintained while it is not. The Trivy gate cannot flag it either: library and
  runtime findings are reported, not gated ([0003](0003-gates-vs-reports.md)).

## Consequences

- Three version lines coexist: `bookworm-v1`, `trixie-v1` and `noble-v1`. The README's image table
  is the source of truth for which image carries which.
- A deprecation is announced in the README with its date ahead of time, so consumers get the
  signal before their image stops rebuilding, not after.
- A retired image's package stays pullable until the owner deletes it. It no longer receives
  rebuilds or re-scans, which is exactly the risk the README's "Tags and rebuilds" section
  describes.
- The specific examples in [0001](0001-mirror-upstream-bases.md) (only `ci-dotnet9` named as
  using MCR) and [0002](0002-images-json-reusable-workflow.md) ("everything else is
  `bookworm-v1`") are now historical. Both records are left as written.

## Revisit if

Debian publishes a newer stable release, which moves the starting point for new images. Also
revisit if an upstream extends a runtime's support after its retirement is announced.
