# Releasing

For maintainers: how a release of this repository is cut, how [CHANGELOG.md](/CHANGELOG.md) is kept, and how the images and the Helm chart are published. The tags themselves, and what each image is: [Images](../reference/images.md).

## Releases

A release is a GitHub release with a calendar version, `vYYYY.MM.DD`, and `.2`, `.3`... for another one the same day. Its tag is on a commit of the default branch. It does not build anything: it names the images the default branch published (and tested) at that point. The image tags stay those of the upstream versions (`syncstorage-rs-mysql-0.24.1`, `fxa-mono-v1.349.0`, the dated `...-<release>-<build date>`, see [Images](../reference/images.md)); the chart's `appVersion` comes from them too.

[release.yml](/.github/workflows/release.yml) cuts one, with [release.py](/.github/scripts/release.py), in two cases:

- **A tag we push.** Tag a commit of the default branch that was the head of a push (it has its CI runs), or a merge of a dependency update (the gate started its CI by hand, [Dependency updates](dependencies.md#what-is-merged-without-a-human)), and push the tag:

  ```bash
  git tag v2026.11.09 <commit>
  git push <remote> v2026.11.09
  ```

  The workflow refuses a commit that is not on the default branch, waits for every CI run of that commit, and releases once all of them passed; one that failed, or no run of the default branch (a push, or a manual run), fails it with the reason.

- **After the weekly runs.** Once the scheduled runs of syncstorage-rs.yml and fxa.yml both completed, there is a release only if something is new since the previous release: the syncstorage-rs, accounts (mozilla/fxa) or pairing server version of the published images, or the [upstream patches](upstream-patches.md) applied to them (the `org.firefox-sync.upstream-patches` label), or entries under Unreleased in CHANGELOG.md. Otherwise the run says why there is none (`nothing new since v2026.11.02: ...`). The tag goes on the commit the weekly runs built. The first run without any release of this kind before releases.

The release:

- the title `vYYYY.MM.DD — syncstorage-rs X.Y.Z, accounts vA.B.C`;
- the notes: the entries of Unreleased (under *Changes*, the empty subsections left out), then *Upstream*: each version with links to Mozilla's release notes of every release since the previous one, the compare link, and syncstorage-rs' CHANGELOG.md with the diff of that file between the versions; the upstream patches applied; then the image tags with their dated build tag and digest, and the chart version when the chart of that commit is published. At the end an HTML comment, `release-state`, records the versions and patches: the next run compares with it;
- then CHANGELOG.md: the entries released move into a section `## vYYYY.MM.DD — YYYY-MM-DD` under Unreleased, which keeps its subsection headings and nothing else (a release without entries gets a line with the upstream versions). A commit of `github-actions[bot]` with `[skip ci]` on the default branch, so no workflow runs for it. Entries added after the commit released stay in Unreleased.

Only that last job, `publish`, can write (`contents: write`); the decision runs with read access.

A copy of the repository that must never release (a development repository that is fast-forwarded into this one) sets its repository variable `FFS_RELEASES=off`: release.yml still decides and prints the notes, and `publish` is skipped, so no tag, release or CHANGELOG.md commit is made there.

To see what would be released now, without releasing:

```bash
GITHUB_REPOSITORY=<owner>/<repository> GITHUB_TOKEN="$(gh auth token)" \
  python3 -I .github/scripts/release.py plan --event manual --dry-run
python3 -I tests/test_release.py
```

On every push to another branch than the default one, release.yml runs that dry run and prints the notes. By hand, *Run workflow* on the default branch with `dry_run` off decides as the weekly run does, without waiting for it. The token needs to read the packages (`read:packages`) for the image tags and labels.

## The changelog

[CHANGELOG.md](/CHANGELOG.md) is what changed for those who run firefox-sync, written for them, not a list of commits. A branch that changes something they see adds its entry under `## Unreleased`, in the subsection it belongs to:

```markdown
## Unreleased

### Breaking

- `SYNC_DB_URL` is now required: set it before upgrading (see docs/upgrading.md).

### Added

### Changed

### Fixed

- The admin UI's storage report counted deleted collections.

### Security
```

An entry is a list item (more lines indented under it), and HTML comments are not entries. Upstream releases need no entry: the release lists them. [tests/check_docs_changed.py](/tests/check_docs_changed.py) warns on a branch that changes a feature without a new entry under Unreleased ([Testing](testing.md#docs-with-the-features)). When a change needs none (a refactor, the tests, CI), say so on a line of its own in a commit message of the push:

```text
Changelog: none (a refactor of the alert code)
```

## The images

Every image is published to `ghcr.io/<owner>/<repository>` only after its tests passed with it ([Testing](testing.md)), and only from the default branch. A branch builds and tests, under tags of its own.

| Image | Workflow | When | Published as |
|---|---|---|---|
| Sync server and its init images | [syncstorage-rs.yml](/.github/workflows/syncstorage-rs.yml) | every Monday from syncstorage-rs' newest release, and on every push but docs-only ones | the per-architecture tags, then the multi-arch `-latest`, `-<release>` and `-<release>-<build date>` |
| accounts and pairing server | [fxa.yml](/.github/workflows/fxa.yml) | every Monday from the newest mozilla/fxa release, on a change of the workflow or of [the upstream patches](upstream-patches.md), or by hand (`version`, `rebuild`) | tags of the run, tested by digest, then the multi-arch tags from those digests |
| admin UI | [admin.yml](/.github/workflows/admin.yml) | every change of `admin/` | the candidate `admin-<sha12>`, tested as published, then tagged `admin-latest`. A newer push cancels an older run, so an older candidate never overwrites `admin-latest` |

- syncstorage-rs.yml reuses an identical image instead of building it again. Its key tag (`syncstorage-rs-<image>-key-<key>-linux-<arch>`) names every input: for the Sync server the upstream tag, `APP_BUILD_REVISION`, the patches applied (and the files of their ports), and a hash of what of this repository goes into the image (the scripts that change the sources, [upstream-patches.py](/.github/scripts/upstream-patches.py) and [syncstorage-rs-build.py](/.github/scripts/syncstorage-rs-build.py), and the build arguments); for an init image the content of its directory. Main writes its key tags, the per-architecture tags and the build cache; a branch writes key tags of its own (`-key-<key>-ref-<branch>-...`) and reuses main's image of the same key too, read only, so a branch builds only the images its change touches. The weekly run and a manual run with `rebuild` start from scratch, to pick up the base images' security updates. Bump `APP_BUILD_REVISION` in the workflow when the way the image is built changes there (the platforms, a step before the build).
- The Sync server's compiled dependencies are a layer of the build cache: upstream's Dockerfile cooks them first with cargo-chef, from a recipe of `Cargo.lock` and the manifests, and syncstorage-rs-build.py drops its cache mounts (empty on every new runner, and not in a registry cache), so that layer keeps them. While the recipe is the same, only syncstorage-rs' own crates compile. The cache is main's (`buildcache-syncstorage-rs-<image>-<release>-linux-<arch>`, `mode=max`); a branch reads it, and writes one of its own (`...-<release>-ref-<branch>-linux-<arch>`) for the Sync server images it builds. The weekly run deletes the caches older than 6 days.
- On a branch, a newer push cancels the older run of syncstorage-rs.yml, fxa.yml and helm.yml: only the latest commit of a branch is tested. Runs of the default branch and the scheduled ones always finish. A tag (a release, a chart version) builds no image.
- None of these workflows makes a GitHub release: [Releases](#releases) are release.yml's.

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
