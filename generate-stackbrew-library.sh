#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# --- Project metadata (per DOI upstream convention: kept in the generator,
#     not in versions.json which only holds per-version data) -----------------
maintainer=$'Lightstreamer Server Development Team <support@lightstreamer.com> (@lightstreamer),\n             Dario Crivelli <dario.crivelli@lightstreamer.com> (@dario-weswit),\n             Gianluca Finocchiaro <gianluca.finocchiaro@lightstreamer.com> (@gfinocchiaro)'
gitrepo="https://github.com/Lightstreamer/Docker.git"

# --- Canonical combination that earns the short/bare tags -------------------
# The image whose (flavor, java, os, variant) matches these four values
# receives `latest`/`<major>`/bare-`<mm>`/bare-`<patch>` (or `-<variant>`
# versions of those, when variant != default_variant).
default_flavor="jdk"
default_java="25"
default_os="noble"
default_variant="full"

# Patch version per "major.minor", plus the ordered list of keys (oldest -> newest).
declare -A patch_of=()
mm_list=()
while read -r mm patch; do
    patch_of[$mm]="$patch"
    mm_list+=( "$mm" )
done < <(jq -r '.versions | to_entries[] | "\(.key) \(.value.version)"' versions.json)

# Latest minor per major (last write wins since mm_list is oldest -> newest)
# and the overall latest major.minor.
declare -A latest_minor_per_major=()
for mm in "${mm_list[@]}"; do
    latest_minor_per_major["${mm%%.*}"]="$mm"
done
overall_latest_mm="${mm_list[-1]}"

# Per-version canonical variant: the (flavor, java, os) triple that this
# version's bare tags (patch, mm, and — when this is the latest minor of its
# major — major) point to. Preferences fall back gracefully:
#   flavor: default_flavor if this version supports it, else its first flavor
#   java:   default_java if that flavor supports it, else its highest java
#   os:     default_os if this version supports it, else its first os
# This lets older versions (that don't ship the global-default Java) still
# earn bare tags like `7.3.3`, `7.3`, `6`, etc.
declare -A canonical_flavor_of=()
declare -A canonical_java_of=()
declare -A canonical_os_of=()
while read -r mm cflavor cjava cos; do
    canonical_flavor_of[$mm]="$cflavor"
    canonical_java_of[$mm]="$cjava"
    canonical_os_of[$mm]="$cos"
done < <(jq -r \
    --arg df "$default_flavor" \
    --arg dj "$default_java" \
    --arg dos "$default_os" '
    .versions | to_entries[]
    | .key as $mm
    | .value.runtimes as $rt
    | .value.os as $oss
    | (if $rt | has($df) then $df else ($rt | keys_unsorted[0]) end) as $cf
    | $rt[$cf] as $javas
    | (if ($javas | index($dj)) then $dj else ($javas | map(tonumber) | max | tostring) end) as $cj
    | (if ($oss | index($dos)) then $dos else $oss[0] end) as $co
    | "\($mm) \($cf) \($cj) \($co)"
' versions.json)
# -----------------------------------------------------------------------------

# All Dockerfiles under <mm>/<flavor><java>/temurin-<os>/Dockerfile.
shopt -s nullglob
image_dirs=( [0-9]*/*/temurin-*/Dockerfile )
image_dirs=( "${image_dirs[@]%/Dockerfile}" )

join_by() {
    # Join args 2..N with the multi-char separator in $1.
    local sep="$1"; shift
    (( $# == 0 )) && return
    local first="$1"; shift
    printf '%s' "$first" "${@/#/$sep}"
}

printf 'Maintainers: %s\nGitRepo: %s\n' "$maintainer" "$gitrepo"
architecture="amd64, arm64v8"

for dir in "${image_dirs[@]}"; do
    # --- Parse the directory path ------------------------------------------
    # Full variant: 7.4/jdk25/temurin-noble         → variant=full
    # Base variant: 7.4/jdk25/temurin-noble-base    → variant=base
    IFS='/' read -r mm flavor_java temurin_os <<<"$dir"
    flavor="${flavor_java%%[0-9]*}"          # jdk | jre
    java="${flavor_java#$flavor}"            # 17 | 21 | 25
    os_and_variant="${temurin_os#temurin-}"  # jammy | noble | jammy-base | noble-base
    if [[ "$os_and_variant" == *-base ]]; then
        variant="base"
        os="${os_and_variant%-base}"
    else
        variant="full"
        os="$os_and_variant"
    fi
    major="${mm%%.*}"
    suffix="${flavor}${java}-temurin-${os}"

    # --- Look up patch version (from versions.json, not the Dockerfile) ---
    patch="${patch_of[$mm]:-}"
    [[ -n "$patch" ]] || { echo >&2 "No patch version for '$mm' in versions.json"; exit 1; }

    commit="$(git log -1 --format='format:%H' -- "$dir")"
    if [[ -z "$commit" ]]; then
        commit="$(git rev-parse HEAD)"
        echo >&2 "warning: $dir has no git history yet; falling back to HEAD ($commit)"
    fi

    # --- Classify this image (1 = yes, 0 = no) ---
    is_latest_minor=0;    [[ "${latest_minor_per_major[$major]}" == "$mm" ]] && is_latest_minor=1
    is_overall_latest=0;  [[ "$mm" == "$overall_latest_mm" ]]               && is_overall_latest=1
    # Canonical = the (flavor, java, os) this version's bare tags point to.
    is_canonical=0
    [[ "$flavor$java$os" == "${canonical_flavor_of[$mm]}${canonical_java_of[$mm]}${canonical_os_of[$mm]}" ]] \
        && is_canonical=1
    # OS-canonical = same version's canonical OS, regardless of flavor/java.
    # Drives the "no-OS" short tags like 7.4.8-jdk11, 7-jre25, etc.
    is_canonical_os=0
    [[ "$os" == "${canonical_os_of[$mm]}" ]] && is_canonical_os=1
    is_default_variant=0; [[ "$variant" == "$default_variant" ]] && is_default_variant=1

    # --- Build the tag list -------------------------------------------------
    # A "-<variant>" suffix is appended to every non-default-variant tag.
    # For the default variant (full) the tags look exactly like they did before.
    if (( is_default_variant )); then
        vsuf=""       # e.g. "7.4.8-jdk25-temurin-noble"
        vbare=""      # e.g. "7.4.8", "latest"
    else
        vsuf="-${variant}"      # e.g. "7.4.8-jdk25-temurin-noble-base"
        vbare="-${variant}"     # e.g. "7.4.8-base", "base"
    fi

    tags=( "${patch}-${suffix}${vsuf}" "${mm}-${suffix}${vsuf}" )
    (( is_latest_minor ))                   && tags+=( "${major}-${suffix}${vsuf}" )
    # Short "no-OS" tags: <ver>-<flavor><java>[-<variant>], one per version level,
    # emitted for images on the canonical OS of their version. Also emits the
    # `-temurin` (no-OS) suffix form for backwards compatibility with the
    # currently-published DOI manifest, which used those before the OS became
    # part of the tag.
    if (( is_canonical_os )); then
        tags+=( "${patch}-${flavor}${java}${vbare}" "${mm}-${flavor}${java}${vbare}" )
        (( is_latest_minor )) && tags+=( "${major}-${flavor}${java}${vbare}" )
        tags+=( "${patch}-${flavor}${java}-temurin${vbare}" "${mm}-${flavor}${java}-temurin${vbare}" )
        (( is_latest_minor )) && tags+=( "${major}-${flavor}${java}-temurin${vbare}" )
    fi
    (( is_canonical ))                      && tags+=( "${patch}${vbare}" "${mm}${vbare}" )
    (( is_canonical && is_latest_minor ))   && tags+=( "${major}${vbare}" )
    (( is_canonical && is_overall_latest )) && tags+=( "$( (( is_default_variant )) && echo latest || echo "${variant}" )" )

    printf '\nTags: %s\nArchitectures: %s\nGitCommit: %s\nDirectory: %s\n' \
        "$(join_by ', ' "${tags[@]}")" "$architecture" "$commit" "$dir"
done