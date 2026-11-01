# Upstream patches

For maintainers: how the images get upstream pull requests before Mozilla releases them, and how to add, update and remove one. Which patches the images have today, and how to read their label: [Upstream patches](../reference/images.md#upstream-patches).

## How it works

The images are built from Mozilla's releases: [fxa.yml](/.github/workflows/fxa.yml) builds mozilla/fxa for `fxa-mono`, [syncstorage-rs.yml](/.github/workflows/syncstorage-rs.yml) builds mozilla-services/syncstorage-rs. [upstream-patches.yml](/upstream-patches.yml) lists the upstream pull requests this project needs now. Its header describes every field.

1. In both workflows, the job that picks the release runs [tests/test_upstream_patches.py](/tests/test_upstream_patches.py) and lists what is to apply.
1. Each build applies it with [.github/scripts/upstream-patches.py](/.github/scripts/upstream-patches.py) to the checked out release, for every architecture: exactly `base...sha` of each entry (or of its [release pin](#release-pins) for that release), never newer commits of the pull request.
1. The image gets the list in its label `org.firefox-sync.upstream-patches`, and the run's summary shows it.
1. The tests then run on those images, as always.

On a branch the images are built and tested, not published. Merged into main, a change of `upstream-patches.yml` rebuilds the current release of the component with it, under the same tags (a new digest). A manual run on main does the same.

- fxa.yml rebuilds when the published image was built for another plan (its label `org.firefox-sync.upstream-patches-plan`). Upstream's code runs in build jobs without write access, which hand an OCI archive to push jobs. These push it under tags of the run (`fxa-mono-<release>-linux-<arch>-run<id>`, the same for the pairing server), the tests use those digests, and main publishes the multi-arch tags from them.
- syncstorage-rs.yml has the patches in the key of the images it reuses. It writes the tags main reuses (keys, per-architecture tags, build cache) from main only; a branch gets key tags of its own.

Both run one at a time per branch.

## Add a pull request

1. Review the pull request at the commit to apply.
1. Pin it: its head repository, the full sha of the reviewed head commit, and of its merge base.

    ```bash
    gh api repos/<repo>/pulls/<pr> --jq '.head.repo.full_name, .head.sha, .base.sha'
    gh api repos/<repo>/compare/<base.sha>...<head.sha> --jq .merge_base_commit.sha   # base
    ```

1. Add the entry to [upstream-patches.yml](/upstream-patches.yml), with why, and what to undo here once it is released (`when_released`).
1. Push to a branch: the images are built and tested with it.

A pull request that moves, is rebased or retargeted changes nothing until the entry does. To update one, review the new commits and move `sha` (and `base` if it was rebased): again a rebuild.

## Rebase one of our pull requests

Upstream pull requests target upstream `main`, which runs ahead of the releases: rebased on it, a pull request can stop applying to the release built here. In the same sitting as the rebase:

1. Note the head before the force push (`gh api repos/<repo>/pulls/<pr> --jq .head.sha`) and its `base`. Afterwards it is the `beforeCommit` of the force push in the pull request's timeline.
1. Move the entry's `base` and `sha` to the new head.
1. If the new head no longer applies to the release built here, pin the old head for that release under `releases` (see below). Check with `upstream-patches.py apply` on a clone of the release.

## Release pins

`releases` maps a release tag to another commit of the same pull request, with its own `base`:

```yaml
  releases:
    v1.348.5:
      base: 3e2cb676f8c561e7c293d44ec979c3be88eb81cb
      sha: a99361eb6229441aa1214a5d6acdf310cc925e02
```

- Building that release, the pin's `base...sha` is applied instead of the entry's. It is a commit of the pull request, so the label is its own `...@<base>..<sha>`, with no `+<release>`.
- The pinned `sha` must have been a head of the pull request: in its history now, or a head before a force push (`beforeCommit` or `afterCommit` of the pull request's force pushes, from GraphQL). `base` must be an ancestor of it. The entry's own `base` and `sha` are checked as always.
- GitHub keeps serving such commits through the pull request for now (`compare base...sha`). If it no longer does, the build fails: save the change as a port instead.
- Any other release gets the entry's `base...sha`. When that does not apply, the build tries the pin of the newest older release with `git apply --check`, then the newest older port. Whatever applies cleanly first is used, and the run warns: review it on the new release and pin it for that release.
- A release pin that does not apply to its own release fails the build, as a port that does not apply does.

mozilla/fxa#21554 has a release pin for v1.348.5: the pull request was rebased on a `main` that removed a script it changed (`backfill-account-authorizations-v2`) and changed `fxa-auth-server`'s `package.json`, so its new head no longer applies to that release. The pin is its head before the rebase.

## Per-release ports

`ports` names a directory of this repository with `<release-tag>.diff` files: the same change made by hand for a release that no commit of the pull request applies to, for example when the code moved between that release and the pull request's base. When a commit of the pull request applies, prefer a [release pin](#release-pins): it is the reviewed change itself.

- Building that release, the file is applied instead (before a release pin for it), and the label says so: `...@base..sha+<release-tag>`.
- Any other release gets its release pin or `base...sha` as always. When `base...sha` does not apply and no older release pin does, the build tries the newest port of an older release with `git apply --check`. If it applies cleanly it is used, the label names that port (`+v1.347.3` on a later release), and the run warns: review the change on the new release and add its port. If nothing applies, the build fails: add a release pin or a port, or rebase the pull request.
- Review a port like the pull request: the release's code, the same change.

(mozilla/fxa#21554 had a port for v1.347.3, where the shared database code was still in `packages/fxa-shared`.)

## What a run says

| The pull request | What happens |
|---|---|
| open, or merged after the release that is built | applied, and the build goes on. A notice if it has commits after the pinned `sha`: they are not applied until `sha` moves |
| merged and in the release (or its changes already in the sources) | not applied; the image is built from the release as it is. After publishing, the job `upstream-patches` fails with the entry and its `when_released`. Publishing is not held back |
| closed without merging, another head repository, a `sha` not in its history, a release pin that was never a head of it or that GitHub no longer serves, changes that don't apply to the release, or merged and released but its changes not in the sources | the build fails and nothing is published. Decide: another pull request, a rebase and a new `sha`, a release pin or a port, or remove the entry and its workaround |

## Remove an entry

In one commit: the entry (its release pins with it), what its `when_released` says, and its `ports` directory if it has one. A red `upstream-patches` job is the reminder.

A release pin, or a port, that no release built here needs any more (the entry's `base...sha` applies to the release built) can go on its own.

An accounts pull request that `prepare_environment.sh` and the tests look for in the label (mozilla/fxa#21494, mozilla/fxa#21554) also gets a line in [config/fxa/fixed-in](/config/fxa/fixed-in): the pull request and the first release with it. Without it, the images built after the removal, which no longer list it, would count as images without it.

## In the tests

Tests that work around an upstream bug read the label. The accounts' tests ([tests/e2e-fxa.sh](/tests/e2e-fxa.sh), [tests/podman.sh](/tests/podman.sh), [tests/helm-fxa.sh](/tests/helm-fxa.sh), [tests/fxa-upgrade.sh](/tests/fxa-upgrade.sh)) decide with [tests/fxa_fix.sh](/tests/fxa_fix.sh), as `prepare_environment.sh` does: the label, or [config/fxa/fixed-in](/config/fxa/fixed-in). [tests/prepare_functions.sh](/tests/prepare_functions.sh) checks both. `tests/e2e.sh` skips upstream's `test_node_assignment.py::test_user_creation` on MariaDB only for images without [mozilla-services/syncstorage-rs#2638](https://github.com/mozilla-services/syncstorage-rs/pull/2638).

## Run it locally

The unit tests, on fixtures, with no network:

```bash
python3 tests/test_upstream_patches.py
```

Against the real pull requests (read-only, `gh` signed in):

```bash
python3 .github/scripts/upstream-patches.py plan fxa-mono v1.347.3
python3 .github/scripts/upstream-patches.py apply <component> <tag> <checkout>   # on a clone of the release
```
