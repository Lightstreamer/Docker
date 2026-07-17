#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# Generate everything into a scratch directory, then swap it in atomically per
# app version. If anything fails, the on-disk tree is untouched.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Explode the manifest into one "mm patch flavor java variant" line per
# (runtime × java × variant) combination. The Cartesian product is driven
# entirely by versions.json — no cross-product code here.
jq -r '
  .variants[] as $var |
  .versions | to_entries[] |
  .key as $mm | .value.version as $patch |
  (.value.runtimes | to_entries[]) as $flav |
  $flav.value[] as $java |
  "\($mm) \($patch) \($flav.key) \($java) \($var)"
' versions.json \
| while read -r APP_VERSION LIGHTSTREAMER_VERSION FLAVOR JAVA_VERSION VARIANT; do
    export APP_VERSION LIGHTSTREAMER_VERSION FLAVOR JAVA_VERSION

    # Legacy patch: Lightstreamer <7.2 had a hard-coded /usr/jdk1.8.0 path in
    # bin/unix-like/LS.sh; rewrite it to $JAVA_HOME so the launch script uses
    # the JDK provided by the eclipse-temurin base image. Empty for 7.2+.
    if [[ "$APP_VERSION" == 6.* || "$APP_VERSION" == "7.0" || "$APP_VERSION" == "7.1" ]]; then
        LEGACY_PATCH=$'# Replace the fictitious jdk path with the JAVA_HOME environment variable in the launch script file\n        && sed -i -- \'s/\\/usr\\/jdk1.8.0/$JAVA_HOME/\' bin/unix-like/LS.sh \\\n'
    else
        LEGACY_PATCH=""
    fi
    export LEGACY_PATCH

    # Full variant: <combo>/            Base variant: <combo>-base/
    # (DOI convention: canonical variant has no suffix, others do.)
    combo="${APP_VERSION}/${FLAVOR}${JAVA_VERSION}"
    if [[ "$VARIANT" == "full" ]]; then
        target_dir="${tmp}/${combo}"
        template="Dockerfile.template"
    else
        target_dir="${tmp}/${combo}-${VARIANT}"
        template="Dockerfile-${VARIANT}.template"
    fi
    mkdir -p "$target_dir"

    envsubst '${JAVA_VERSION} ${FLAVOR} ${LIGHTSTREAMER_VERSION} ${LEGACY_PATCH}' \
        < "$template" > "${target_dir}/Dockerfile"

    echo "Generated: ${target_dir#"$tmp/"}/Dockerfile (Lightstreamer ${LIGHTSTREAMER_VERSION}, ${VARIANT})"
done

# Everything generated successfully — swap each version tree into place.
while read -r mm; do
    rm -rf "./${mm}"
    mv "${tmp}/${mm}" "./${mm}"
done < <(jq -r '.versions | keys_unsorted[]' versions.json)

echo "Update complete! All version directories generated."