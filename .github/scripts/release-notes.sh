#!/bin/bash
# Prints the GitHub release notes: the commits of this repository since the previous
# release, then the upstream changelog of the syncstorage-rs version that was built.
# Run from a full clone of this repository (history and tags).
#
# Usage: release-notes.sh <service_tag> <build_date> <upstream_changelog> <previous_release_tag> <owner/repo> [server_url]
set -eu

SERVICE_TAG=$1
BUILD_DATE=$2
UPSTREAM_CHANGELOG=$3
PREVIOUS=$4
REPOSITORY=$5
SERVER=${6:-https://github.com}
UPSTREAM=mozilla-services/syncstorage-rs

commit_list() {
  git log --no-merges --reverse --format="* %s ([%h](${SERVER}/${REPOSITORY}/commit/%H))" "$@"
}

echo "Built on ${BUILD_DATE} from upstream [syncstorage-rs ${SERVICE_TAG}](${SERVER}/${UPSTREAM}/releases/tag/${SERVICE_TAG})."
echo ""
echo "## Changes in ${REPOSITORY}"
echo ""
if [ -n "${PREVIOUS}" ] && git rev-parse -q --verify "refs/tags/${PREVIOUS}" > /dev/null; then
  changes=$(commit_list "${PREVIOUS}..HEAD")
  echo "Since the previous release, [${PREVIOUS}](${SERVER}/${REPOSITORY}/releases/tag/${PREVIOUS}):"
  echo ""
  echo "${changes:-* no changes}"
else
  commit_list HEAD
fi
echo ""

# the section of the upstream changelog for this version: from its anchor to the next one,
# with the version heading moved into our own heading and its sections one level lower
upstream=$(awk -v tag="${SERVICE_TAG}" '
  $0 ~ "^<a name=\"" tag "\"" { inside = 1; next }
  inside && /^<a name=/ { exit }
  inside && !heading && /^## / {
    heading = 1
    date = ""
    if (match($0, /\([0-9-]+\)/)) date = " " substr($0, RSTART, RLENGTH)
    print "## Upstream changes in syncstorage-rs " tag date
    next
  }
  inside { sub(/^#### /, "### "); print }
' "${UPSTREAM_CHANGELOG}" 2> /dev/null | cat -s)
if [ -n "${upstream}" ]; then
  echo "${upstream}"
else
  echo "## Upstream changes in syncstorage-rs ${SERVICE_TAG}"
  echo ""
  echo "See the [upstream release](${SERVER}/${UPSTREAM}/releases/tag/${SERVICE_TAG})."
fi
