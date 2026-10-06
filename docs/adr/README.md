# Architecture decision records

Short records of the decisions that shape this repository — the ones a newcomer would otherwise
re-litigate, reverse-engineer from commit messages, or accidentally undo. Each record states the
decision, the reasoning that made it win, and what would have to change for it to be revisited.

| ADR | Decision |
|---|---|
| [0001](0001-mirror-upstream-bases.md) | Mirror upstream base images into GHCR |
| [0002](0002-images-json-reusable-workflow.md) | One `images.json`, one reusable workflow, per-image change detection |
| [0003](0003-gates-vs-reports.md) | Security gates block only what this repo can fix (library part superseded by 0006) |
| [0004](0004-sha-pinned-actions.md) | Actions pinned by commit SHA, maintained by Dependabot with a cooldown |
| [0005](0005-new-images-current-distro-retire-at-eol.md) | New images start on the current distro; images retire at upstream end of support (distribution rule amended by 0009) |
| [0006](0006-gate-on-fixable-library-vulnerabilities.md) | The vulnerability gate fails on fixable library findings too (supersedes part of 0003; gate and alerts-report parts superseded by 0008) |
| [0007](0007-automatic-updates.md) | Pinned tools and Dependabot updates merge themselves when safe and green; the rest wait for review (merge and review parts superseded by 0008) |
| [0008](0008-self-updating.md) | Self-updating: the gate blocks only what a build adds, everything runs daily, green bot PRs merge themselves |
| [0009](0009-image-lifecycle.md) | The image lifecycle runs itself: new runtime lines added, old ones deprecated 120 days ahead and retired after end of support; new images on the newest Debian stable, else the newest Ubuntu LTS (amends 0005) |

Records are immutable once accepted; a change of course gets a new record that supersedes the old
one, so the history of *why* survives the history of *what*.
