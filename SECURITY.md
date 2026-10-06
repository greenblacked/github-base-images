# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately via
[GitHub Security Advisories](https://github.com/greenblacked/github-base-images/security/advisories/new)
rather than opening a public issue.

Include the image and tag (ideally the digest — `docker buildx imagetools inspect
ghcr.io/greenblacked/<image>:bookworm-v1`), the architecture, and how to reproduce.

## Scope

These are **CI images**: they run build and test commands in GitHub Actions container jobs. They
are not runtime images and are not intended to be exposed to untrusted network input.

In scope:

- A credential, token, or private key baked into a published image. The secret scan gates on this
  at any severity, so anything that ships is a real escape.
- A fixable HIGH/CRITICAL vulnerability that a build added and the gate should have caught — in an
  OS package, or in a library or binary in the image (a pinned tool, or a package the runtime's
  upstream image bundles). The gate covers both. A released fix that still has not reached the
  image a few days after the seven-day update cooldown is in scope too: the daily rebuild and the
  automated updates should have picked it up.
- A supply-chain problem with how images are built or published — an unexpected base, a tag
  pointing at a digest this repo did not build, or a published digest whose cosign signature or
  GitHub attestation does not verify under the identity documented in the README's
  [Verifying an image](README.md#verifying-an-image) section. The pipeline checks both right after
  signing, so one that does not verify is a real escape.

Out of scope:

- Unfixed vulnerabilities with no patched version available upstream, whether in an OS package or
  in the language runtimes' own bundled dependencies (npm's transitive packages, Python wheels
  shipped in the upstream base, and so on). These are reported by the scan but do not gate; the
  gate uses `ignore-unfixed` deliberately — see
  [Tests and security scanning](docs/security.md#tests-and-security-scanning).
- Known upstream findings: a vulnerability whose advisory names a fixed version that no release of
  the upstream software contains yet (pip's vendored urllib3, say), and which the published image
  already carried. These ship until upstream releases the fix, and are listed in every build's
  gate summary and in the alerts report
  ([ADR 0008](docs/adr/0008-self-updating.md)).
- Findings from the Dockerfile misconfiguration scan (missing `USER`, and similar). These images
  need root to run `apt`, and the scan is reported rather than gating for that reason.

## Supported versions

Only each image's current rolling tag (`bookworm-v1`, `trixie-v1` or `noble-v1` — see the
[image catalog](README.md#image-catalog) in the README) is supported. It is rebuilt daily,
picking up distribution security updates; older digests are never patched in place. Pin a digest
for reproducibility, but expect to move it forward to receive fixes.

`ci-dotnet8` and `ci-dotnet9` are deprecated: .NET 8 and .NET 9 reach end of support on
2026-11-10, and both images are retired after that date. Use `ci-dotnet10`.
