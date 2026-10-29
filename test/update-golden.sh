#!/usr/bin/env bash
# Regenerates test/golden-manifest.txt (the manifest without GitCommit lines) and
# prints what changed, so an intentional tag change is reviewed, not rubber-stamped.
# Run ./update.sh first if versions.json or a template changed.

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

golden=test/golden-manifest.txt
new="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$new" "$err"' EXIT

if ! ./generate-stackbrew-library.sh 2> "$err" | grep -v '^GitCommit:' > "$new"; then
    echo "FAIL: generate-stackbrew-library.sh failed:" >&2
    cat "$err" >&2
    exit 1
fi

if [[ -f "$golden" ]]; then
    if diff -u "$golden" "$new"; then
        echo "No change: $golden is already up to date."
        exit 0
    fi
else
    echo "(no previous $golden; creating it)"
fi

cp "$new" "$golden"
echo
echo "Updated $golden. Review the diff above and commit it only if every change is intended."
