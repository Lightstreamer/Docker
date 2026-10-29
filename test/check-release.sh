#!/usr/bin/env bash
# Release gate — run on an up-to-date master after generating ./lightstreamer.
#
# regression.sh ignores GitCommit lines because they depend on history and merge
# style. This script checks them instead, for the manifest you are about to
# publish. For every block it asserts that:
#   - the commit exists and is reachable from the default branch;
#   - the commit contains <Directory>/Dockerfile;
#   - <Directory> is identical at that commit and at the tip of the default
#     branch (the manifest is not stale).
#
# Usage: ./test/check-release.sh [manifest]     (default: ./lightstreamer)
# Env:   DEFAULT_REF=origin/master              (run `git fetch origin` first)

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

manifest="${1:-lightstreamer}"
ref="${DEFAULT_REF:-origin/master}"

if [[ ! -f "$manifest" ]]; then
    echo "FAIL: $manifest not found. Run: ./generate-stackbrew-library.sh > $manifest"
    exit 1
fi
if ! git rev-parse --verify --quiet "${ref}^{commit}" > /dev/null; then
    echo "FAIL: $ref not found. Run: git fetch origin"
    exit 1
fi

# Reachability on a fork's branch doesn't prove DOI can fetch the commit: the remote must be GitRepo.
norm() {
    local u="${1%.git}"
    u="${u/#git@github.com:/https://github.com/}"
    echo "${u,,}"
}
remote="${ref%%/*}"
remote_url="$(git remote get-url "$remote" 2> /dev/null || true)"
gitrepo="$(sed -n 's/^GitRepo: //p' "$manifest")"
if [[ -z "$remote_url" || "$(norm "$remote_url")" != "$(norm "$gitrepo")" ]]; then
    echo "FAIL: remote '$remote' (${remote_url:-none}) is not the manifest's GitRepo ($gitrepo)."
    echo "      Use DEFAULT_REF=<remote>/master with the remote that points at GitRepo."
    exit 1
fi

fail=0
blocks=0
commit=""
problem() { echo "FAIL: $1: $2"; fail=1; }

while read -r key value; do
    case "$key" in
        GitCommit:) commit="$value" ;;
        Directory:)
            dir="$value"
            blocks=$((blocks + 1))
            if ! git cat-file -e "${commit}^{commit}" 2> /dev/null; then
                problem "$dir" "commit $commit does not exist locally"
            elif ! git merge-base --is-ancestor "$commit" "$ref"; then
                problem "$dir" "commit $commit is not reachable from $ref (merge and fetch first)"
            elif ! git cat-file -e "${commit}:${dir}/Dockerfile" 2> /dev/null; then
                problem "$dir" "commit $commit has no $dir/Dockerfile (directory has no git history?)"
            elif ! git diff --quiet "$commit" "$ref" -- "$dir"; then
                problem "$dir" "changed on $ref after $commit; regenerate the manifest"
            fi
            ;;
        *) ;;
    esac
done < "$manifest"

if (( blocks == 0 )); then
    echo "FAIL: no image blocks found in $manifest"
    exit 1
fi
if (( fail )); then
    echo
    echo "CHECK-RELEASE: FAILED"
    exit 1
fi
echo "OK ($blocks images, all commits reachable from $ref and current)"
echo "CHECK-RELEASE: OK"
