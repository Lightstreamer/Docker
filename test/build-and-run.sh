#!/usr/bin/env bash
# Build every image, and for every full-edition variant, run it and verify
# /lightstreamer/healthcheck returns 2xx within 60 seconds. Base-edition
# variants are built (which validates the Dockerfile) but not run — they
# ship without conf/*.xml and cannot start standalone.
#
# Tests whatever is currently on disk. Run ./update.sh first if versions.json
# or a template changed.
#
# Exit 0 on all-green. Non-zero if any build or run fails.

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v curl >/dev/null   || { echo "curl is required" >&2; exit 1; }

shopt -s nullglob
image_dirs=( [0-9]*/*/Dockerfile )
image_dirs=( "${image_dirs[@]%/Dockerfile}" )
(( ${#image_dirs[@]} > 0 )) || { echo "no images to test (run ./update.sh first?)" >&2; exit 1; }

# Clean up any leftover test containers on exit (Ctrl-C, errors, normal exit).
cleanup() {
    # shellcheck disable=SC2046
    docker ps -aq --filter 'label=lightstreamer-check' \
        | xargs -r docker rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass=0 fail=0 skip=0
failures=()

for dir in "${image_dirs[@]}"; do
    tag="lightstreamer-check:$(tr '/' '-' <<<"$dir")"
    printf '\n=== %s ===\n' "$dir"

    # --- build ---
    if ! docker build -t "$tag" "$dir" >/tmp/build.log 2>&1; then
        echo "BUILD FAILED"
        tail -20 /tmp/build.log
        fail=$((fail + 1))
        failures+=("build: $dir")
        continue
    fi
    echo "build OK"

    # --- run (skip for base — no conf) ---
    if [[ "$dir" == *-base ]]; then
        echo "run:  SKIP (base edition; needs downstream conf)"
        skip=$((skip + 1))
        pass=$((pass + 1))
        continue
    fi

    cid=$(docker run -d --label lightstreamer-check \
              -p 127.0.0.1:0:8080 "$tag")
    port=$(docker port "$cid" 8080 | awk -F: '{print $NF; exit}')

    # Wait up to 60s for Lightstreamer's /lightstreamer/healthcheck endpoint
    # to return 2xx, OR for the container to die. `curl -f` makes non-2xx
    # count as failure, so we keep polling while the server is still starting.
    started=false
    deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
        if curl -fsS --connect-timeout 3 --max-time 5 \
                -o /dev/null "http://127.0.0.1:${port}/lightstreamer/healthcheck" 2>/dev/null; then
            started=true
            break
        fi
        if ! docker ps -q --no-trunc | grep -q "$cid"; then
            break   # container exited early
        fi
        sleep 1
    done

    if $started; then
        echo "run:  OK (/lightstreamer/healthcheck responded on port ${port})"
        pass=$((pass + 1))
    else
        echo "RUN FAILED — last 30 lines of container logs:"
        docker logs "$cid" 2>&1 | tail -30 | sed 's/^/  /'
        fail=$((fail + 1))
        failures+=("run: $dir")
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
done

echo
echo '========================================'
printf 'Total images:            %d\n' "${#image_dirs[@]}"
printf '  Passed:                %d\n' "$pass"
printf '  Failed:                %d\n' "$fail"
printf '  Runtime skipped (base): %d\n' "$skip"

if (( fail > 0 )); then
    echo
    echo 'Failures:'
    printf '  %s\n' "${failures[@]}"
    exit 1
fi
