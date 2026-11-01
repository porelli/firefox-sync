# Releasing

For maintainers: how the images and the Helm chart are published. The tags themselves, and what each image is: [Images](../reference/images.md).

## The images

Every image is published to `ghcr.io/<owner>/<repository>` only after its tests passed with it ([Testing](testing.md)), and only from the default branch. A branch builds and tests, under tags of its own.

| Image | Workflow | When | Published as |
|---|---|---|---|
| Sync server and its init images | [syncstorage-rs.yml](/.github/workflows/syncstorage-rs.yml) | every Monday from syncstorage-rs' newest release, and on every push but docs-only ones | the per-architecture tags, then the multi-arch `-latest`, `-<release>` and `-<release>-<build date>` |
| accounts and pairing server | [fxa.yml](/.github/workflows/fxa.yml) | every Monday from the newest mozilla/fxa release, on a change of the workflow or of [the upstream patches](upstream-patches.md), or by hand (`version`, `rebuild`) | tags of the run, tested by digest, then the multi-arch tags from those digests |
| admin UI | [admin.yml](/.github/workflows/admin.yml) | every change of `admin/` | the candidate `admin-<sha12>`, tested as published, then tagged `admin-latest`. A newer push cancels an older run, so an older candidate never overwrites `admin-latest` |

- syncstorage-rs.yml reuses an identical image (same upstream tag, same patches, same build revision) instead of building it again. The weekly run, a manual run with `rebuild`, and a release start from scratch, to pick up the base images' security updates. Bump `APP_BUILD_REVISION` in the workflow when the way the image is built changes.
- On a branch, a newer push cancels the older run of syncstorage-rs.yml, fxa.yml and helm.yml: only the latest commit of a branch is tested. Runs of the default branch, of tags and the scheduled ones always finish.
- A tagged commit on the default branch also gets a GitHub release from syncstorage-rs.yml. Its notes come from [release-notes.sh](/.github/scripts/release-notes.sh): this repository's commits since the previous release, then the upstream changelog of the syncstorage-rs version that was built.

## The Helm chart

[helm.yml](/.github/workflows/helm.yml) publishes the chart on a tag `chart-v<version>`, the version of `Chart.yaml`, after every test of the workflow passed.

1. Set `version` in [Chart.yaml](/charts/firefox-sync/Chart.yaml).
1. Tag the commit `chart-v<version>` and push the tag.

What the workflow checks and does:

- [chart-version.sh](/.github/scripts/chart-version.sh) refuses a tag that is not `chart-v<version>`. A stable version must come from a commit of the default branch. A pre-release (`0.1.0-dev.1`) can come from any branch, to test the publishing: `helm install` without `--version` or `--devel` never picks one.
- A version is published once, never replaced: [chart-unpublished.sh](/.github/scripts/chart-unpublished.sh) fails when the registry has it, or does not clearly answer that it is missing.
- The chart goes to `oci://ghcr.io/<owner>/<repository>/charts/firefox-sync` (for this repository `oci://ghcr.io/porelli/firefox-sync/charts/firefox-sync`). `Chart.yaml`'s annotation `org.firefox-sync/chart` is set to that address: the admin UI's `helm upgrade` commands show it, with the release's `--version`.
- The publish job holds `packages: write`, so it pins its third-party action (`azure/setup-helm`) by commit, and its Helm to one version (`PUBLISH_HELM_VERSION`), checked against that release's sha256. The other jobs use tags, and the latest Helm: move the publish job's to a version they passed with.

## Package visibility

A new package starts private on GitHub. Make it public once, in the package's settings.
