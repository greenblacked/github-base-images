# Documentation

The [README](../README.md) is the consumer summary: quick start, the image catalog, what a green
publish guarantees, and how to verify an image. These pages hold the detail behind it.

| Page | Covers |
|---|---|
| [images.md](images.md) | What each image contains and why; deprecations; Playwright; using the tool images; visibility and authentication; running and building an image locally; future candidates |
| [security.md](security.md) | The smoke test and the five Trivy scans; which gate and which report; the Security tab and OSV; vulnerability exceptions; verifying signatures and attestations; repository security checks; required checks; the alerts report |
| [pipeline.md](pipeline.md) | Mirrored upstream bases; PR validation and linting; which images a run builds; native multi-arch builds; tags and rebuilds; `digests.json`; pin drift; automatic updates |

Elsewhere in the repository:

- [CONTRIBUTING.md](../CONTRIBUTING.md): the local loop, pre-PR checks, adding another image, and
  bumping pinned tools and their checksums.
- [SECURITY.md](../SECURITY.md): reporting a vulnerability, scope, supported versions.

## Architecture decision records

Why the repository is built the way it is. The [ADR index](adr/README.md) explains how records are
kept.

| ADR | Decision |
|---|---|
| [0001](adr/0001-mirror-upstream-bases.md) | Mirror upstream base images into GHCR |
| [0002](adr/0002-images-json-reusable-workflow.md) | One `images.json`, one reusable workflow, per-image change detection |
| [0003](adr/0003-gates-vs-reports.md) | Security gates block only what this repo can fix (library part superseded by 0006) |
| [0004](adr/0004-sha-pinned-actions.md) | Actions pinned by commit SHA, maintained by Dependabot with a cooldown |
| [0005](adr/0005-new-images-current-distro-retire-at-eol.md) | New images start on the current distro; images retire at upstream end of support |
| [0006](adr/0006-gate-on-fixable-library-vulnerabilities.md) | The vulnerability gate fails on fixable library findings too (supersedes part of 0003) |
| [0007](adr/0007-automatic-updates.md) | Pinned tools and Dependabot updates merge themselves when safe and green; the rest wait for review |
