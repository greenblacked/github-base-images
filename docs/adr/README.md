# Architecture decision records

Short records of the decisions that shape this repository — the ones a newcomer would otherwise
re-litigate, reverse-engineer from commit messages, or accidentally undo. Each record states the
decision, the reasoning that made it win, and what would have to change for it to be revisited.

| ADR | Decision |
|---|---|
| [0001](0001-mirror-upstream-bases.md) | Mirror upstream base images into GHCR |
| [0002](0002-images-json-reusable-workflow.md) | One `images.json`, one reusable workflow, per-image change detection |
| [0003](0003-gates-vs-reports.md) | Security gates block only what this repo can fix |
| [0004](0004-sha-pinned-actions.md) | Actions pinned by commit SHA, maintained by Dependabot with a cooldown |

Records are immutable once accepted; a change of course gets a new record that supersedes the old
one, so the history of *why* survives the history of *what*.
