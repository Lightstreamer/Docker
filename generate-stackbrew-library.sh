#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# --- Project metadata (per DOI upstream convention: kept in the generator,
#     not in versions.json which only holds per-version data) -----------------
maintainer=$'Lightstreamer Server Development Team <support@lightstreamer.com> (@lightstreamer),\n             Dario Crivelli <dario.crivelli@lightstreamer.com> (@dario-weswit),\n             Gianluca Finocchiaro <gianluca.finocchiaro@lightstreamer.com> (@gfinocchiaro)'
gitrepo="https://github.com/Lightstreamer/Docker.git"

# --- Canonical combination that earns the short/bare tags -------------------
# The image whose (flavor, java, variant) matches these three values receives
# `latest`/`<major>`/bare-`<mm>`/bare-`<patch>` (or `-<variant>` versions of
# those, when variant != default_variant).
default_flavor="jdk"
default_java="25"
default_variant="full"

# Patch version per "major.minor", plus the ordered list of keys (oldest -> newest).
declare -A patch_of=()
mm_list=()
# Uses `< <(jq …)` (process substitution) rather than `jq … | while` so the
# loop runs in the current shell and its assignments to patch_of/mm_list
# survive after `done`. A pipe would put the loop in a subshell.
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

# Per-version canonical combination: the (flavor, java) pair that this
# version's bare tags (patch, mm, and — when this is the latest minor of its
# major — major) point to. Preferences fall back gracefully:
#   flavor: default_flavor if this version supports it, else its first flavor
#   java:   default_java if that flavor supports it, else its highest java
# This lets older versions (that don't ship the global-default Java) still
# earn bare tags like `7.3.3`, `7.3`, `6`, etc.
declare -A canonical_flavor_of=()
declare -A canonical_java_of=()
while read -r mm cflavor cjava; do
    canonical_flavor_of[$mm]="$cflavor"
    canonical_java_of[$mm]="$cjava"
done < <(jq -r \
    --arg df "$default_flavor" \
    --arg dj "$default_java" '
    .versions | to_entries[]
    | .key as $mm
    | .value.runtimes as $rt
    | (if $rt | has($df) then $df else ($rt | keys_unsorted[0]) end) as $cf
    | $rt[$cf] as $javas
    | (if ($javas | index($dj)) then $dj else ($javas | map(tonumber) | max | tostring) end) as $cj
    | "\($mm) \($cf) \($cj)"
' versions.json)
# -----------------------------------------------------------------------------

# All Dockerfiles under <mm>/<flavor><java>[-<variant>]/Dockerfile. The glob
# returns them in lexicographic order (jdk11 < jdk17 < ... < jdk25 < jdk8),
# which is wrong: `sort -V` gives numeric-aware order — jdk8 before jdk11,
# and a "-base" sibling right after its default-variant counterpart.
shopt -s nullglob
image_dirs=( [0-9]*/*/Dockerfile )
image_dirs=( "${image_dirs[@]%/Dockerfile}" )
mapfile -t image_dirs < <(printf '%s\n' "${image_dirs[@]}" | sort -V)

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
    # Full variant: 7.4/jdk25         → variant=full
    # Base variant: 7.4/jdk25-base    → variant=base
    IFS='/' read -r mm flavor_java_variant <<<"$dir"
    if [[ "$flavor_java_variant" == *-base ]]; then
        variant="base"
        flavor_java="${flavor_java_variant%-base}"
    else
        variant="full"
        flavor_java="$flavor_java_variant"
    fi
    flavor="${flavor_java%%[0-9]*}"          # jdk | jre
    java="${flavor_java#$flavor}"            # 17 | 21 | 25
    major="${mm%%.*}"

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
    # Canonical = the (flavor, java) this version's bare tags point to.
    is_canonical=0
    [[ "$flavor$java" == "${canonical_flavor_of[$mm]}${canonical_java_of[$mm]}" ]] \
        && is_canonical=1
    is_default_variant=0; [[ "$variant" == "$default_variant" ]] && is_default_variant=1

    # --- Build the tag list -------------------------------------------------
    # A "-<variant>" suffix is appended to every non-default-variant tag; the
    # default variant (full) gets an empty suffix.
    if (( is_default_variant )); then
        vsuf=""       # e.g. "7.4.8-jdk25"
    else
        vsuf="-${variant}"      # e.g. "7.4.8-jdk25-base"
    fi

    # Primary (flavor+java) tags, plus a "-temurin" mirror kept for
    # backwards compatibility with the previously-published DOI manifest.
    tags=(
        "${patch}-${flavor}${java}${vsuf}"          "${mm}-${flavor}${java}${vsuf}"
        "${patch}-${flavor}${java}-temurin${vsuf}"  "${mm}-${flavor}${java}-temurin${vsuf}"
    )
    if (( is_latest_minor )); then
        tags+=(
            "${major}-${flavor}${java}${vsuf}"
            "${major}-${flavor}${java}-temurin${vsuf}"
        )
    fi
    # Bare tags (no flavor/java suffix) — only for the canonical (flavor,java)
    # of this mm.
    (( is_canonical ))                      && tags+=( "${patch}${vsuf}" "${mm}${vsuf}" )
    (( is_canonical && is_latest_minor ))   && tags+=( "${major}${vsuf}" )
    (( is_canonical && is_overall_latest )) && tags+=( "$( (( is_default_variant )) && echo latest || echo "${variant}" )" )

    # Example output block (full-variant, canonical image on 7.4):
    #   Tags: 7.4.8-jdk25, 7.4-jdk25,
    #         7.4.8-jdk25-temurin, 7.4-jdk25-temurin,
    #         7-jdk25, 7-jdk25-temurin,
    #         7.4.8, 7.4, 7, latest
    #   Architectures: amd64, arm64v8
    #   GitCommit: 156c40…
    #   Directory: 7.4/jdk25
    printf '\nTags: %s\nArchitectures: %s\nGitCommit: %s\nDirectory: %s\n' \
        "$(join_by ', ' "${tags[@]}")" "$architecture" "$commit" "$dir"
done
