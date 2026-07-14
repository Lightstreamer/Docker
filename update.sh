#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# Generate everything into a scratch directory, then swap it in atomically per
# app version. If anything fails, the on-disk tree is untouched.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Explode the manifest into one "mm patch flavor java os variant" line per
# (runtime × java × os × variant) combination. The Cartesian product is driven
# entirely by versions.json — no cross-product code here.
jq -r '
  .variants[] as $var |
  .versions | to_entries[] |
  .key as $mm | .value.version as $patch |
  (.value.runtimes | to_entries[]) as $flav |
  $flav.value[] as $java |
  .value.os[] as $os |
  "\($mm) \($patch) \($flav.key) \($java) \($os) \($var)"
' versions.json \
| while read -r APP_VERSION LIGHTSTREAMER_VERSION FLAVOR JAVA_VERSION OS_VARIANT VARIANT; do
    export APP_VERSION LIGHTSTREAMER_VERSION FLAVOR JAVA_VERSION OS_VARIANT

    # Full variant: <combo>/            Base variant: <combo>-base/
    # (DOI convention: canonical variant has no suffix, others do.)
    combo="${APP_VERSION}/${FLAVOR}${JAVA_VERSION}/temurin-${OS_VARIANT}"
    if [[ "$VARIANT" == "full" ]]; then
        target_dir="${tmp}/${combo}"
        template="Dockerfile.template"
    else
        target_dir="${tmp}/${combo}-${VARIANT}"
        template="Dockerfile-${VARIANT}.template"
    fi
    mkdir -p "$target_dir"

    envsubst '${JAVA_VERSION} ${FLAVOR} ${OS_VARIANT} ${LIGHTSTREAMER_VERSION}' \
        < "$template" > "${target_dir}/Dockerfile"

    echo "Generated: ${target_dir#"$tmp/"}/Dockerfile (Lightstreamer ${LIGHTSTREAMER_VERSION}, ${VARIANT})"
done

# Everything generated successfully — swap each version tree into place.
while read -r mm; do
    rm -rf "./${mm}"
    mv "${tmp}/${mm}" "./${mm}"
done < <(jq -r '.versions | keys_unsorted[]' versions.json)

echo "Update complete! All version directories generated."