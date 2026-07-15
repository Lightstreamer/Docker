#!/usr/bin/env bash
# Layer 1 — static lint: shellcheck, versions.json schema, hadolint.
# Missing tools are soft-skipped; real failures exit non-zero.

set -Eeuo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

fail=0
step() { printf '\n=== %s ===\n' "$1"; }

# --- shellcheck ---
step "shellcheck"
if ! command -v shellcheck >/dev/null; then
    echo "SKIP: shellcheck not installed"
else
    scripts=( update.sh generate-stackbrew-library.sh )
    while IFS= read -r -d '' f; do scripts+=( "$f" ); done \
        < <(find test -type f -name '*.sh' -print0)
    shellcheck --severity=warning "${scripts[@]}" || fail=1
fi

# --- jq ---
# check_jq wraps a boolean jq expression; -e exits non-zero on false/null.
check_jq() {
    local msg="$1"; shift
    if ! jq -e "$1" versions.json > /dev/null 2>&1; then
        echo "FAIL: $msg"
        fail=1
    fi
}

step "jq: versions.json is well-formed"
jq empty versions.json || fail=1

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

step "jq: version key is a prefix of the patch version"
check_jq "version keys match their patch versions" \
    '[.versions | to_entries[] | .key as $k | .value.version | startswith($k + ".")] | all'

# --- hadolint ---
step "hadolint: generated Dockerfiles"
if ! command -v hadolint >/dev/null; then
    echo "SKIP: hadolint not installed"
else
    shopt -s nullglob
    dockerfiles=( [0-9]*/*/temurin-*/Dockerfile )
    if (( ${#dockerfiles[@]} == 0 )); then
        echo "SKIP: no generated Dockerfiles present (run ./update.sh first)"
    else
        # DL3008: apt version pinning (buildpack-deps ships what we need).
        # SC2016: literal $JAVA_HOME in single quotes (intentional in legacy sed).
        for f in "${dockerfiles[@]}"; do
            hadolint --ignore DL3008 --ignore SC2016 "$f" || fail=1
        done
        echo "linted ${#dockerfiles[@]} generated Dockerfiles"
    fi
fi

echo
(( fail )) && { echo "LINT: FAILED"; exit 1; }
echo "LINT: OK"
