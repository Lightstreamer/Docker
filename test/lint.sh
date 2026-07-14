#!/usr/bin/env bash
# Layer 1 — static lint.
#
# No side effects, no file writes. Runs:
#   - shellcheck on every shell script in the repo
#   - jq well-formedness + schema invariants on versions.json
#   - hadolint on Dockerfile.template
#
# Missing tools are treated as SKIP (soft-fail). A real failure sets fail=1
# and the script exits non-zero at the end.

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

fail=0
step() { printf '\n=== %s ===\n' "$1"; }

# --- shellcheck ---------------------------------------------------------------
step "shellcheck"
if ! command -v shellcheck >/dev/null; then
    echo "SKIP: shellcheck not installed"
else
    scripts=( update.sh generate-stackbrew-library.sh )
    while IFS= read -r -d '' f; do scripts+=( "$f" ); done \
        < <(find test -type f -name '*.sh' -print0)
    shellcheck --severity=warning "${scripts[@]}" || fail=1
fi

# --- jq: well-formedness ------------------------------------------------------
step "jq: versions.json is well-formed"
if ! jq empty versions.json; then
    fail=1
fi

# --- jq: schema invariants ----------------------------------------------------
# Each check is a single boolean expression; -e makes jq exit non-zero if the
# last output is false/null. Wrapping in "[…] | all" reduces a stream to one
# boolean, which is what -e wants.

check_jq() {
    local msg="$1"; shift
    if ! jq -e "$1" versions.json > /dev/null 2>&1; then
        echo "FAIL: $msg"
        fail=1
    fi
}

step "jq: top-level shape"
check_jq ".variants is a non-empty array of strings" \
    '.variants | type == "array" and length > 0 and all(.[]; type == "string")'
check_jq ".versions is a non-empty object" \
    '.versions | type == "object" and (to_entries | length > 0)'

step "jq: every version has a semver-shaped patch and non-empty runtimes/os"
check_jq "each .version matches N.N.N" \
    '[.versions[] | .version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")] | all'
check_jq "each .runtimes is a non-empty object" \
    '[.versions[] | .runtimes | type == "object" and (to_entries | length > 0)] | all'
check_jq "each .os is a non-empty array of strings" \
    '[.versions[] | .os | type == "array" and length > 0 and all(.[]; type == "string")] | all'
check_jq "each runtimes[flavor] is a non-empty array of strings" \
    '[.versions[] | .runtimes | to_entries[] | .value | type == "array" and length > 0 and all(.[]; type == "string")] | all'

step "jq: version key is a prefix of the patch version (e.g. \"7.4\" -> \"7.4.8\")"
check_jq "version keys match their patch versions" \
    '[.versions | to_entries[] | .key as $k | .value.version | startswith($k + ".")] | all'

# NOTE: The old "default (flavor, java, os) exists in overall-latest" checks
# were dropped when defaults moved out of versions.json into
# generate-stackbrew-library.sh. If the hardcoded defaults there don't match
# a real image, the "'latest' appears exactly once" check in regression.sh
# catches it downstream (the latest tag simply won't be assigned).

# --- hadolint -----------------------------------------------------------------
step "hadolint: Dockerfile templates"
if ! command -v hadolint >/dev/null; then
    echo "SKIP: hadolint not installed"
else
    # DL3006 (untagged FROM): false positive for FROM eclipse-temurin:${JAVA_VERSION}-... .
    # DL3008 (pin apt versions): buildpack-deps ships the tools we need, we don't install more.
    for f in Dockerfile.template Dockerfile-*.template; do
        [[ -f "$f" ]] || continue
        hadolint --ignore DL3006 --ignore DL3008 "$f" || fail=1
    done
fi

# --- summary ------------------------------------------------------------------
echo
if (( fail )); then
    echo "LINT: FAILED"
    exit 1
fi
echo "LINT: OK"
