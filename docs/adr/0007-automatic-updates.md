# 0007 — Automatic updates: bots propose, CI decides, a human reviews what CI cannot

**Status:** accepted

## Decision

Every image stays up to date without a human noticing drift. Two kinds of update are automated,
and both go through an ordinary pull request that runs the full CI and every required check.
Nothing merges red, and nothing merges by any path other than GitHub auto-merge waiting on the
`main` ruleset.

**Dependabot** (action pins, each image's `ARG BASE_IMAGE`):
[dependabot-auto-merge.yml](../../.github/workflows/dependabot-auto-merge.yml) enables auto-merge
(squash) on minor and patch updates, and on nothing else. Majors get the `needs-review` label and
no auto-merge, and so does any update whose type `fetch-metadata` could not determine.

**Hand-pinned tools** (the `ARG *_VERSION` pins, osv-scanner in `build-image.yml`, gitleaks in
`security.yml`, hadolint and actionlint in `scripts/lint.sh`):
[pin-bump.yml](../../.github/workflows/pin-bump.yml) runs weekly, after pin drift. It takes the
drift report from `scripts/check-pins.sh`, and for each tool that is behind:

1. `scripts/bump-pins.sh` rewrites the version and every checksum next to it, on a branch
   `pin-bump/<tool>` cut from `main`. Pins kept in more than one place move as one unit:
   kubectl (ci-tools, ci-cloud), Composer (ci-php84, ci-php85), gitleaks (ci-security,
   security.yml), npm and Playwright (ci-node22, ci-node24).
2. `scripts/pin-bump-prs.sh` commits as `github-actions[bot]`, opens or updates one PR per unit,
   dispatches CI on the branch, and then either enables auto-merge or labels it.

Each bump is classified:

| Class | When | What happens |
|---|---|---|
| `auto` | vendor-published checksum or registry integrity, not a semver major, released at least 7 days ago | auto-merge (squash) once every required check passes |
| `review` | no vendor checksum (AWS CLI, Docker client, gcloud), a major version, or a release date that could not be established | PR opened, labelled `needs-review`, auto-merge off |
| deferred | released less than 7 days ago | no PR this week |

As of this record, `auto` covers terraform, kubectl, trivy, syft, grype, cosign, gitleaks,
golang-migrate, osv-scanner, hadolint, actionlint, Composer (from getcomposer.org's published
`composer.phar.sha256sum`), npm, Playwright and the json gem. A major version of any of them is
`review`. npm, Playwright and json are version pins installed by their package managers, not
checksum pins: npm verifies the registry's sha512 integrity on install, while `gem install` does
not check the sha256 rubygems.org publishes, so for json the bump confirms that digest exists and
the trust is otherwise the registry's, exactly as it was for the hand-set pin.

**Checksums come only from the vendor.** `bump-pins.sh` reads each checksum from the vendor's own
checksums file or registry record for that exact version, and never hashes a download to produce
one. A hash computed from our own fetch attests only to what we happened to fetch. The build's
`sha256sum --check` then cross-verifies vendor file against vendor artifact; if they disagree, CI
is red and nothing merges.

**Publishing after a merge: the weekly rebuild, nothing extra.** A merge made by auto-merge under
the workflow token triggers no `push` workflow (below), so `build-and-push.yml` does not run on
it. The bumped image is published by the next scheduled rebuild, Monday 04:17 UTC, at most a week
later. `pin-bump.yml` does not try to dispatch a `main` build after merges: it cannot know when an
auto-merge lands, and a scheduled "did anything merge since the last publish?" job would be one
more moving part to publish something the weekly rebuild publishes anyway. Anyone who wants a
bump live sooner runs *Build and Push to GHCR* on `main` by hand.

## Why

- The pins were the one part of the supply chain nothing moved. Pin drift made the gap visible,
  but a tracking issue still needed a human to prepare a three-line PR with fresh checksums, and
  an audit found six tools behind at once. The work is mechanical exactly where it is safe
  (checksum from vendor, minor or patch, CI green) and needs judgement exactly where it is not (no
  checksum, a major), so the split follows that line.
- **Why the checks run by dispatch.** Events caused by the workflow's `GITHUB_TOKEN` do not start
  workflows: the bump branch's push and PR would trigger no `pull_request` run, and the required
  checks would never report. `workflow_dispatch` is the documented exception. `pin-bump-prs.sh`
  runs `gh workflow run build-and-push.yml --ref pin-bump/<tool>` and the same for `security.yml`.
  The check runs land on the branch head, which is the PR's head, and the ruleset matches
  required checks by name, so the PR's checks are the same checks a human's PR gets. The cost is
  that a dispatched Build and Push always rebuilds every image (the `plan` job selects all images
  on dispatch), about an hour of runners per bump PR. That is accepted in exchange for needing no
  PAT and no GitHub App.
- **Dependency review on dispatch.** A job skipped by its `if:` reports its check as skipped,
  which a required check counts as passing. So a required `Dependency review` that only ran on
  `pull_request` would have gone green on every bump PR without looking. `security.yml` now runs
  it on a dispatch from any branch other than `main` too, comparing `main` with the dispatched
  commit via the action's `base-ref`/`head-ref` inputs. On `pull_request` it runs exactly as
  before. For the same reason Scorecard, which fails outright on any ref but the default branch,
  now runs on `main` only.
- **Why the ruleset is read first.** Auto-merge is only as strong as what it waits for; with no
  required checks it merges at once. Both workflows read the `main` rules through the API and
  enable auto-merge only if `CI result`, `Repository secret scan`, `CodeQL (workflows)` and
  `Dependency review` are all required. Otherwise they leave the PR open and say which are
  missing.
- **Cooldown.** Dependabot waits seven days before proposing any version (ADR 0004). The pin
  bumps apply the same seven days, measured from the vendor's release date, for the same reason:
  the window between publication and discovery of a compromised release is when a same-day bump
  would pull it in.
- **Why an unknown update type counts as a major.** `fetch-metadata` reports an empty update
  type whenever it cannot parse a version, which is the case for a SHA-pinned action with no
  version comment. That SHA can be a patch or a new major, and nothing short of resolving both
  SHAs to release tags tells them apart. Auto-merging them as "digest-only" updates would merge
  a major on the strength of a missing comment. Every action
  here carries its version comment (ADR 0004), so the case is rare, and a human reading it
  costs little.
- **Why the pin-bump job runs from `main` only.** Its token pushes branches, edits PRs and
  dispatches workflows. A dispatch from another branch would hand that token to that branch's
  unreviewed copy of the scripts, and `DRY_RUN` is only a request those scripts could ignore.
  So the writing job runs on `main` whatever the input says, and a dispatch from any other
  branch runs a separate `preview` job instead: a dry run whose token can read the PRs, rules
  and check runs and write nothing.
- **Why `pull_request`, not `pull_request_target`, for Dependabot.** On `pull_request` a fork's PR
  gets a read-only token whatever the workflow asks for, so a mistake in the Dependabot condition
  cannot hand out write access. Under `pull_request_target` that condition would be the only
  guard. Nothing in either workflow checks out or runs PR code.

## Consequences

- **Idempotent, self-healing weekly runs.** An open PR at an older version has its branch
  rebuilt from `main` and force-pushed, leased to the SHA the run saw, and its title and body
  rewritten. An open PR already at the target version, on a branch that is up to date, is not
  rebuilt but is checked: if the required checks never reported on its head commit (a dispatch
  that failed, say), each workflow whose checks are missing is dispatched again; and if it is
  an `auto` PR with auto-merge off while the ruleset now qualifies, auto-merge is turned on. A
  check that ran and failed is left red: it is a result for a human, and re-dispatching it
  weekly would only burn runners. A PR a maintainer closed unmerged is not reopened for the
  same version. A tool that fails, including a failed dispatch or an unreadable check-run
  list, is reported and the run goes red, but only after every other tool was processed.
- **A human commit makes the branch hands-off.** A branch with any commit whose author or
  committer is not `github-actions[bot]` is never force-pushed, re-dispatched or given
  auto-merge: someone is working on it, and auto-merge would merge their commit unreviewed.
  That includes GitHub's *Update branch* button, whose merge commit is authored by whoever
  clicked it. Such a PR stays as it is until its owner merges it by hand, or hands it back by
  dropping their commits so the branch is the bot's again (the command is in
  [Automatic updates](../pipeline.md#automatic-updates)); the next run then rebuilds or heals
  it. Deleting the branch closes the PR, and a closed PR is not reopened for the same version.
- **Composer becomes vendor-attested on its first automated bump.** The current pin is
  trust-on-first-use (CONTRIBUTING.md). The next one comes from getcomposer.org's published
  digest, or the bump fails; it never falls back to hashing the download.
- A `review` PR has already been through the full CI when a human opens it; the review is about
  whether to adopt the release, not whether it builds.
- The repository needs these settings, and neither workflow can set them itself:
  1. *Settings → Actions → General → Workflow permissions:* **Allow GitHub Actions to create and
     approve pull requests.** Without it, `gh pr create` under the workflow token is refused and
     every bump fails.
  2. *Settings → General → Pull Requests:* **Allow auto-merge**, and **Allow squash merging**.
  3. *Settings → Rules → Rulesets → `main`:* **require the status checks** `CI result`,
     `Repository secret scan`, `CodeQL (workflows)` and `Dependency review`. They are listed in
     [Required checks](../security.md#required-checks).
  4. If the ruleset also requires an approving review, `auto` PRs wait for one: the workflow token
     cannot approve its own PR. That is a legitimate choice; it just turns "merges itself" into
     "merges on approval".

  When auto-merge cannot be enabled, the run stays green, warns in its summary with these exact
  settings, and leaves the PR open. Once the settings are in place, the next weekly run enables
  it on the PRs still open.

## Revisit if

- A vendor in the `review` class starts publishing checksums, or its signature is verified in the
  build (AWS's detached GPG signature). It then moves to `auto`.
- Publishing a week after merge proves too slow in practice. The first step would be a
  `workflow_run` or scheduled job that dispatches `build-and-push.yml` on `main` when `main` has
  commits by `github-actions[bot]` newer than the last successful publish.
- GitHub lets `GITHUB_TOKEN` events trigger workflows, which would make the dispatch unnecessary.
