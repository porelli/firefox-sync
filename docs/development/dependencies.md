# Dependency updates

For maintainers: how this repository's own dependencies are kept current with Dependabot, what gets merged without a human, and what stays for one. The upstream services (syncstorage-rs, mozilla/fxa, the pairing server) are not dependencies of this kind: the weekly builds take their newest release ([Releasing](releasing.md#the-images)).

## What is updated

[.github/dependabot.yml](/.github/dependabot.yml) asks for version updates every Wednesday at 06:00 UTC (not on Monday, when the weekly image builds and the release run):

| Ecosystem | Where | Pull requests | Commit subject |
|---|---|---|---|
| Go modules | `admin/go.mod` (the admin UI) | one for all minor and patch updates (group `admin-go`), one per major update | `fix(deps): bump ...` |
| GitHub Actions | the workflows and the composite actions of `.github/actions/` | one for all minor and patch updates (group `actions`), one per major update | `ci(deps): bump ...` |

The workflows use actions by major tag (`actions/checkout@v7`), which follows that major's releases by itself: Dependabot opens a pull request for them only when a new major comes out. The one action pinned by commit, `azure/setup-helm` in the publish job of helm.yml ([Releasing](releasing.md#the-helm-chart)), gets a pull request for each of its releases.

Not updated by Dependabot, on purpose: few pins, the newest versions, and a break gets fixed rather than pinned:

- **The base images** of the Dockerfiles (`golang:1`, `gcr.io/distroless/static:nonroot`, `debian:stable-slim`, `postgres:latest`, `mariadb:lts`). They are floating tags, so every build takes the newest image. Dependabot only bumps version tags, so it would have nothing to do here except propose `golang:2` some day.
- **docs/requirements.txt** has one unpinned name (`mkdocs-material`), and every docs build installs the newest. Dependabot can only bump pinned versions, so it would have to add pins.

### Security updates

Dependabot alerts and Dependabot security updates are on (*Settings*, *Advanced Security*). A security update is a pull request of its own and goes through the same gate: merged when it is a minor or patch update, left open when it is a major one.

## What is merged without a human

[dependencies.yml](/.github/workflows/dependencies.yml) is the gate. It runs on every Dependabot pull request against the default branch, each time the pull request is opened, reopened or updated. [.github/scripts/dependencies.py](/.github/scripts/dependencies.py) decides, waits and starts the runs. Its self-test is [tests/test_dependencies.py](/tests/test_dependencies.py), run by the gate and by docs.yml on every push.

1. **The update type**, from [dependabot/fetch-metadata](https://github.com/dependabot/fetch-metadata) (for a group, the highest of its updates):
   - semver minor or patch: merged once CI passed;
   - major, or unknown: left open for a human, with the reason in the run's summary. Unknown means fetch-metadata has none, for example when a commit on the branch is not Dependabot's;
   - an update that moves an action pinned by commit (a `uses: ...@<40 hex>` line added) is left open too, whatever its type. That pin is there for security, so a human checks the new commit.
1. **The wait.** It waits until every workflow run of the pull request's head commit has completed. Every workflow that a push of the pull request's files starts must have a run of that commit. When Dependabot rebases a branch, its push changes other files than the update. A workflow that then has no run of the head commit after three minutes is started by hand (`workflow_dispatch`) on the branch, and the gate waits for it too. One failed or cancelled run fails the gate, and nothing is merged. It gives up after about five hours.
1. **The merge.** A squash merge: the subject is the pull request's title, and the body links the gate's run and says `Changelog: none (dependency update)` and `Docs: none (dependency update)`. The merge only goes through if the head commit is still the one that was tested (`--match-head-commit`). Then the gate deletes the branch.
1. **Main's CI.** A merge made with the workflow's `GITHUB_TOKEN` starts no `push` workflow on main. So the gate itself starts, by hand on main, every workflow that a push of those files to main would have started. It reads each workflow's `on.push` filters (`branches`, `paths`, `paths-ignore`), as GitHub does. For a Go update, for example: admin.yml, docs.yml, helm.yml and syncstorage-rs.yml. release.yml is left out, because its push run does nothing on main. These manual runs publish as a push to main does: `admin-latest`, the Sync server's multi-arch tags, the accounts images, and the docs site (docs.yml's deploy job also runs for a manual run on the default branch). The commit can be tagged for a release: [release.py](/.github/scripts/release.py) counts a manual run on the default branch as its CI ([Releasing](releasing.md#releases)).

There is no branch protection and no required check, and the repository's auto-merge setting is not used. The gate is what merges. So a maintainer's direct push to main and the release bot's CHANGELOG.md commit work as before.

### When the gate failed

- A run failed for a reason that has nothing to do with the update (a flaky test): re-run that run, then re-run the gate's failed job.
- The update breaks something: fix it on the branch, or in a commit to main, then comment `@dependabot rebase` on the pull request. Once someone else has pushed to the branch, fetch-metadata has no update type, so the gate leaves the pull request for a human.
- The merge failed because the branch is behind or in conflict: Dependabot rebases it on its own (or after `@dependabot rebase`), and the gate runs again for the new head.

### A major update

Read the release notes, check the pull request's CI runs, and merge it in the web UI (squash). That merge is yours, not the workflow token's, so it is a push to main like any other and starts main's CI by itself.

## Dependabot's own runs

The branches are Dependabot's (`dependabot/...`) and live in this repository, so their `push` runs are Dependabot's (actor `dependabot[bot]`). Such a run gets a read-only `GITHUB_TOKEN`, except where a job's `permissions:` raise it. Every job of these workflows that writes (the image builds that push to ghcr.io with `packages: write`) declares its permissions, so its run builds and pushes under the branch's own tags as any branch does. Such a run gets only Dependabot secrets, never Actions secrets. The workflows use no secret but `GITHUB_TOKEN`.

The docs check of a branch ([tests/check_docs_changed.py](/tests/check_docs_changed.py), [Testing](testing.md#docs-with-the-features)) only warns, and Dependabot's files (`admin/go.mod`, `admin/go.sum`, the workflows) are not features in its sense. The squash commit on main carries the `Changelog: none` and `Docs: none` lines.

## Turning it off

- Stop merging, and keep the pull requests: disable the gate (`gh workflow disable dependencies.yml`, or *Actions*, *dependencies*, *Disable workflow*). Enable it again with `gh workflow enable`.
- Stop the version updates: remove the ecosystem from [.github/dependabot.yml](/.github/dependabot.yml), or set `open-pull-requests-limit: 0` on it. Pull requests already open stay open.
- Stop the security updates: *Settings*, *Advanced Security*, *Dependabot security updates*. The alerts stay on.

## Repository settings

The setup expects these settings, on this repository and on any repository the code moves to:

| Setting | Value | API |
|---|---|---|
| Dependabot alerts | on | `PUT repos/<owner>/<repo>/vulnerability-alerts` |
| Dependabot security updates | on | `PUT repos/<owner>/<repo>/automated-security-fixes` |
| Squash merging | allowed (the default) | `allow_squash_merge` |
| Workflow permissions | read (the default): each job raises its own | `actions/permissions/workflow` |

Not needed: the auto-merge setting (`allow_auto_merge`), automatic deletion of head branches, branch protection or rulesets on main.
