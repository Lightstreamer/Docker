#!/usr/bin/env bash
# Layer 2 — generator regression.
#
# Tests whatever is currently on disk. It is the developer's responsibility
# to run ./update.sh beforehand if versions.json or a template changed.
#
# Asserts:
#   - No unresolved template placeholders (${JAVA_VERSION} etc.) remain in
#     generated Dockerfiles.
#   - generate-stackbrew-library.sh runs cleanly.
#   - No duplicate tags across the whole manifest.
#   - The tag `latest` appears exactly once.
#   - The generated stackbrew manifest matches the committed golden file
#     (./lightstreamer), if one exists.
#
# On any failure prints a diagnostic and exits non-zero.

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

step() { printf '\n=== %s ===\n' "$1"; }

# --- No unresolved template placeholders --------------------------------------
step "generated Dockerfiles: envsubst placeholders all resolved"
unresolved=$(grep -RHnE '\$\{(JAVA_VERSION|JDK_JRE|OS_VARIANT|LIGHTSTREAMER_VERSION)\}' \
    [0-9]*/*/temurin-*/Dockerfile 2>/dev/null || true)
if [[ -n "$unresolved" ]]; then
    echo "FAIL: unresolved template placeholders:"
    echo "$unresolved"
    exit 1
fi
echo "OK"

# --- generate-stackbrew-library.sh --------------------------------------------
step "generate-stackbrew-library.sh: runs"
./generate-stackbrew-library.sh > /tmp/stackbrew.new 2> /tmp/stackbrew.err || {
    echo "FAIL: generator exited non-zero"
    cat /tmp/stackbrew.err >&2
    exit 1
}
if [[ -s /tmp/stackbrew.err ]]; then
    echo "(stderr warnings, non-fatal):"
    sed 's/^/  /' /tmp/stackbrew.err >&2
fi
echo "OK ($(wc -l < /tmp/stackbrew.new) lines)"

# Helper: emit every tag as one per line.
tags_stream() {
    awk '/^Tags:/{sub(/^Tags: /,""); gsub(/, /,"\n"); print}' /tmp/stackbrew.new
}

# --- Tag consistency: no duplicates -------------------------------------------
step "no duplicate tags"
dupes="$(tags_stream | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
    echo "FAIL: duplicate tags:"
    echo "$dupes"
    exit 1
fi
echo "OK"

# --- Tag consistency: 'latest' appears exactly once ---------------------------
step "'latest' appears exactly once"
count="$(tags_stream | grep -cx 'latest' || true)"
if [[ "$count" != 1 ]]; then
    echo "FAIL: 'latest' appears $count time(s) (expected 1)"
    exit 1
fi
echo "OK"

# --- Golden-file diff ---------------------------------------------------------
step "matches committed 'lightstreamer' manifest"
if [[ ! -f lightstreamer ]]; then
    echo "SKIP: no committed 'lightstreamer' golden file"
else
    if ! diff -u lightstreamer /tmp/stackbrew.new > /tmp/stackbrew.diff; then
        echo "FAIL: stackbrew manifest differs from committed 'lightstreamer'."
        echo
        head -60 /tmp/stackbrew.diff
        cat >&2 <<-EOM

If the change is intentional, regenerate the golden and commit it alongside
your other changes:

    ./generate-stackbrew-library.sh > lightstreamer

EOM
        exit 1
    fi
    echo "OK"
fi

echo
echo "REGRESSION: OK"
