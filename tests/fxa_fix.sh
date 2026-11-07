# shellcheck shell=bash
# Sourced by the tests that choose the accounts' database by the accounts image: whether an
# image has a fix of upstream-patches.yml (mozilla/fxa#21494 for MariaDB 12, mozilla/fxa#21709
# for MySQL 9), decided as prepare_environment.sh decides it (fxa_has_fix): its label
# org.firefox-sync.upstream-patches, or once Mozilla released it its release from that one on
# (config/fxa/fixed-in, the label org.opencontainers.image.version, else the tag).
FXA_FIX_CODE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# fxa_fixed <pull request> <patches label> <version label> <tag>: 0 yes, 1 no, 2 not known
fxa_fixed() {
  # (prepare_environment.sh sourced: its functions only)
  (source "${FXA_FIX_CODE}/prepare_environment.sh" && fxa_has_fix "$@")
}
# fxa_image_fixed <pull request> <image> [docker|podman]: the local image (pulled before)
fxa_image_fixed() {
  local labels runtime=${3:-docker} field=.Config.Labels
  [ "${runtime}" = podman ] && field=.Labels
  labels=$(${runtime} image inspect -f "{{index ${field} \"org.firefox-sync.upstream-patches\"}}|{{index ${field} \"org.opencontainers.image.version\"}}" "$2" 2> /dev/null) || labels="|"
  labels=${labels//<no value>/}
  fxa_fixed "$1" "${labels%%|*}" "${labels#*|}" "$(fxa_image_tag "$2")"
}
# fxa_registry_fixed <pull request> <image>: the registry's image (docker buildx imagetools)
fxa_registry_fixed() {
  local json
  json=$(docker buildx imagetools inspect "$2" --format '{{json .Image}}' 2> /dev/null) || return 2
  (source "${FXA_FIX_CODE}/prepare_environment.sh" && fxa_inspected_has "$1" "${json}" "$(fxa_image_tag "$2")")
}
# the tag of an image name (none for a digest)
fxa_image_tag() { case "${1##*/}" in *@*) ;; *:*) printf '%s' "${1##*:}" ;; esac; }
