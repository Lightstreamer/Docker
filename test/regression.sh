#!/usr/bin/env bash
# Layer 2 — generator regression.
#
# Tests whatever is currently on disk, and fails if the generated Dockerfiles
# are out of date with versions.json or the templates (run ./update.sh).
# With --committed it tests HEAD in a clean checkout instead, ignoring any
# uncommitted changes (what a reviewer or CI would see).
#
# Usage: ./test/regression.sh [--committed]
#
# Asserts:
#   - The generated Dockerfiles match what ./update.sh would produce from
#     versions.json and the templates (no missing, extra or stale files).
#   - Every ${VAR} in the templates is substituted by update.sh (its envsubst
#     list) or declared in the template via ARG/ENV.
#   - No unresolved template placeholders (those named in update.sh's envsubst
#     list) remain in generated Dockerfiles.
#   - generate-stackbrew-library.sh runs cleanly.
#   - No duplicate tags across the whole manifest.
#   - The tag `latest` appears exactly once, on the newest version's default
#     full-edition image.
#   - The generated stackbrew manifest, minus its GitCommit lines, matches the
#     committed golden file (test/golden-manifest.txt).
#
# On any failure prints a diagnostic and exits non-zero.

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

step() { printf '\n=== %s ===\n' "$1"; }

for tool in git jq envsubst; do
    command -v "$tool" > /dev/null || { echo "FAIL: '$tool' is required (see Prerequisites in docs/making-changes.md)"; exit 1; }
done

work="$(mktemp -d)"
cleanup() { git worktree remove --force "$work/head" 2> /dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

case "${1:-}" in
    "") ;;
    --committed)
        git worktree add --quiet --detach "$work/head" HEAD
        echo "Testing committed HEAD ($(git rev-parse --short HEAD)); working-tree changes are ignored."
        rc=0
        "$work/head/test/regression.sh" || rc=$?
        exit "$rc"
        ;;
    *) echo "usage: $0 [--committed]" >&2; exit 2 ;;
esac

# --- Generated tree is up to date ---------------------------------------------
step "generated Dockerfiles are up to date with versions.json and templates"
scratch="$work/scratch"
mkdir "$scratch"
cp update.sh versions.json Dockerfile.template Dockerfile-base.template "$scratch/"
if ! (cd "$scratch" && ./update.sh > "$work/update.out" 2>&1); then
    echo "FAIL: update.sh failed on the current versions.json and templates:"
    cat "$work/update.out"
    exit 1
fi
expected_mm="$(jq -r '.versions | keys[]' versions.json | sort)"
actual_mm="$(for d in [0-9]*/; do if [[ -d "$d" ]]; then echo "${d%/}"; fi; done | sort)"
drift=""
if [[ "$expected_mm" != "$actual_mm" ]]; then
    drift+="version directories on disk differ from versions.json:"$'\n'
    drift+="$(diff <(echo "$expected_mm") <(echo "$actual_mm") || true)"$'\n'
fi
for mm in $expected_mm; do
    drift+="$(diff -rq "$scratch/$mm" "$mm" 2>&1 || true)"$'\n'
done
if [[ -n "${drift//[$'\n']/}" ]]; then
    echo "FAIL: generated Dockerfiles are out of date. Run ./update.sh."
    echo "$drift" | sed '/^$/d' | head -40
    exit 1
fi
echo "OK"

# --- Template variables are all accounted for ---------------------------------
# update.sh's envsubst argument is the single source of truth for substituted names.
subst_vars="$(sed -n "s/.*envsubst '\([^']*\)'.*/\1/p" update.sh | grep -oE '[A-Za-z_][A-Za-z_0-9]*' || true)"
if [[ -z "$subst_vars" ]]; then
    echo "FAIL: could not read the envsubst variable list from update.sh"
    exit 1
fi

step "templates: every \${VAR} is substituted by update.sh or declared via ARG/ENV"
undeclared=""
for t in Dockerfile.template Dockerfile-base.template; do
    declared="$(sed -nE 's/^(ARG|ENV) ([A-Za-z_][A-Za-z_0-9]*).*/\2/p' "$t")"
    while read -r name; do
        [[ -n "$name" ]] || continue
        grep -qxF "$name" <<<"$subst_vars"$'\n'"$declared" || undeclared+="  $t: \${$name}"$'\n'
    done < <(grep -oE '\$\{[A-Za-z_][A-Za-z_0-9]*' "$t" | sed 's/^\${//' | sort -u)
done
if [[ -n "$undeclared" ]]; then
    echo "FAIL: template variables neither substituted by update.sh nor declared via ARG/ENV:"
    printf '%s' "$undeclared"
    echo "Add them to the envsubst list in update.sh, or declare them in the template."
    exit 1
fi
echo "OK"

# --- No unresolved template placeholders --------------------------------------
step "generated Dockerfiles: envsubst placeholders all resolved"
alt="$(paste -sd'|' <<<"$subst_vars")"
unresolved=$(grep -RHnE '\$\{('"$alt"')\}' \
    [0-9]*/*/Dockerfile 2>/dev/null || true)
if [[ -n "$unresolved" ]]; then
    echo "FAIL: unresolved template placeholders:"
    echo "$unresolved"
    exit 1
fi
echo "OK"

# --- generate-stackbrew-library.sh --------------------------------------------
step "generate-stackbrew-library.sh: runs"
./generate-stackbrew-library.sh > "$work/stackbrew.new" 2> "$work/stackbrew.err" || {
    echo "FAIL: generator exited non-zero"
    cat "$work/stackbrew.err" >&2
    exit 1
}
if [[ -s "$work/stackbrew.err" ]]; then
    echo "(stderr warnings, non-fatal):"
    sed 's/^/  /' "$work/stackbrew.err" >&2
fi
echo "OK ($(wc -l < "$work/stackbrew.new") lines)"

# Helper: emit every tag as one per line.
tags_stream() {
    awk '/^Tags:/{sub(/^Tags: /,""); gsub(/, /,"\n"); print}' "$work/stackbrew.new"
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

# --- 'latest' is on the right image -------------------------------------------
step "'latest' is the newest version's default full-edition image"
default_flavor="$(sed -n 's/^default_flavor="\(.*\)"$/\1/p' generate-stackbrew-library.sh)"
default_java="$(sed -n 's/^default_java="\(.*\)"$/\1/p' generate-stackbrew-library.sh)"
if [[ -z "$default_flavor" || -z "$default_java" ]]; then
    echo "FAIL: could not read default_flavor/default_java from generate-stackbrew-library.sh"
    exit 1
fi
newest_mm="$(jq -r '.versions | keys_unsorted | last' versions.json)"
newest_patch="$(jq -r --arg mm "$newest_mm" '.versions[$mm].version' versions.json)"
# Paragraph mode: one record per manifest block; prints "<Directory>|, <tags>," for the block tagged latest.
latest_block="$(awk -v RS= -F'\n' '
    { tags = ""; dir = "" }
    { for (i = 1; i <= NF; i++) {
        if ($i ~ /^Tags: /)      tags = ", " substr($i, 7) ","
        if ($i ~ /^Directory: /) dir = substr($i, 12)
      }
      if (tags ~ /, latest,/) print dir "|" tags }' "$work/stackbrew.new")"
latest_dir="${latest_block%%|*}"
latest_tags="${latest_block#*|}"
problems=""
if [[ "$latest_dir" != "$newest_mm/"* || "$latest_dir" == *-base ]]; then
    problems+="  'latest' is on $latest_dir, expected a full-edition image of $newest_mm"$'\n'
fi
if [[ "$latest_tags" != *", $newest_patch,"* || "$latest_tags" != *", $newest_mm,"* ]]; then
    problems+="  that image lacks the $newest_patch and/or $newest_mm tags"$'\n'
fi
# When the newest version doesn't offer default_java, the generator falls back to its highest Java; skip then.
if jq -e --arg mm "$newest_mm" --arg dj "$default_java" \
    '.versions[$mm].runtimes | to_entries | map(.value | index($dj)) | any' versions.json > /dev/null; then
    if [[ "$latest_dir" != "$newest_mm/${default_flavor}${default_java}" ]]; then
        problems+="  expected $newest_mm/${default_flavor}${default_java}, got $latest_dir"$'\n'
    fi
fi
if [[ -n "$problems" ]]; then
    echo "FAIL: 'latest' is misplaced:"
    printf '%s' "$problems"
    exit 1
fi
echo "OK ($latest_dir)"

# --- Golden-file diff ---------------------------------------------------------
step "matches golden manifest (test/golden-manifest.txt)"
golden=test/golden-manifest.txt
if [[ ! -f "$golden" ]]; then
    echo "FAIL: golden file $golden is missing. Create it with:"
    echo "    ./test/update-golden.sh"
    exit 1
else
    # GitCommit hashes depend on history and merge style, so they are not compared.
    if ! grep -v '^GitCommit:' "$work/stackbrew.new" | diff -u "$golden" - > "$work/stackbrew.diff"; then
        echo "FAIL: stackbrew manifest differs from $golden."
        echo
        head -60 "$work/stackbrew.diff"
        cat >&2 <<-EOM

If the change is intentional, regenerate the golden (it shows the diff) and
commit it alongside your other changes:

    ./test/update-golden.sh

EOM
        exit 1
    fi
    echo "OK"
fi

echo
if [[ -n "$(git status --porcelain -- '[0-9]*' test versions.json update.sh generate-stackbrew-library.sh Dockerfile.template Dockerfile-base.template)" ]]; then
    echo "NOTE: files this test reads have uncommitted changes, and this run tested them."
    echo "      Commit first, or run './test/regression.sh --committed' to test HEAD only."
fi
echo "REGRESSION: OK"
