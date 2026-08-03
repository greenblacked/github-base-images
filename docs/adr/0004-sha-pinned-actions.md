# 0004 — Actions pinned by commit SHA, maintained by Dependabot with a cooldown

**Status:** accepted

## Decision

Every remote `uses:` is pinned to a full commit SHA with the version in a trailing comment
(`uses: owner/action@<sha> # vX.Y.Z`). Dependabot maintains the pins (it understands and updates
this form) under a 7-day `cooldown`, and zizmor's default `hash-pin` policy enforces the practice
— a tag-pinned action is a finding, not a style choice. Pins are resolved from tags via
`git ls-remote` and re-verified against live refs after writing.

## Why

- A repo whose entire purpose is producing trusted base images was pinning its own supply chain
  by **mutable tag** while telling consumers to pin digests. A moved tag is precisely the attack
  a version comment cannot prevent and a SHA can.
- The cooldown closes the adjacent window: if an upstream release is compromised, the time
  between publication and discovery is exactly when a same-day bump would pull it in. The cost —
  security fixes delayed by the same margin — is acceptable because the weekly rebuild plus the
  Trivy gate already deliver OS-level fixes without waiting on action bumps.
- The same reasoning extends past `uses:`: the ci-tools binaries, Composer, gitleaks, and the
  local lint engines are all pinned release artifacts verified by checksum, not floating tags.

## Consequences

- zizmor runs with **no configuration file**; the strict default applies. If `unpinned-uses`
  findings reappear, pin the action rather than relaxing the policy.
- Bumps arrive as Dependabot PRs that update SHA and comment together; PR validation runs the
  full affected pipeline, so a bump is pre-verified before merge.
- Majors still deserve a human read of the changelog — the pin makes the *ref* trustworthy, not
  the release.

## Revisit if

GitHub ships immutable action releases with enforced provenance, making tag pins equivalent to
SHA pins.
