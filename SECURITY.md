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
- A fixable HIGH/CRITICAL OS-package vulnerability that the build gate should have caught.
- A supply-chain problem with how images are built or published — an unexpected base, a tag
  pointing at a digest this repo did not build.

Out of scope:

- Vulnerabilities in the language runtimes' own bundled dependencies (npm's transitive packages,
  Python wheels shipped in the upstream base, and so on). These are reported by the scan but do not
  gate, because they are not fixable from this repository — see the README's "Tests and security
  scanning" section.
- Unfixed OS CVEs with no patch available upstream. The gate uses `ignore-unfixed` deliberately.
- Findings from the Dockerfile misconfiguration scan (missing `USER`, and similar). These images
  need root to run `apt`, and the scan is reported rather than gating for that reason.

## Supported versions

Only the current rolling tag (`bookworm-v1`) is supported. It is rebuilt weekly, picking up Debian
security updates; older digests are never patched in place. Pin a digest for reproducibility, but
expect to move it forward to receive fixes.
