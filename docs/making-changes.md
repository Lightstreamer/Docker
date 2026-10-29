# Making changes to this repository

This document is for anyone modifying the Lightstreamer Docker images — whether you're bumping a patch version, adding a new Java runtime, or changing the Dockerfile itself. It describes the generation pipeline, gives a playbook for each common change, and — in the last section — explains how to publish the result to [Docker Official Images](https://hub.docker.com/_/lightstreamer).

## How the repository is organised

```
├── versions.json                     ← Source of truth for versions × runtimes × variants
├── Dockerfile.template               ← Template for the "full" edition
├── Dockerfile-base.template          ← Template for the "base" edition
├── update.sh                         ← Regenerates the Dockerfile tree from versions.json
├── generate-stackbrew-library.sh     ← Generates the `lightstreamer` manifest
├── lightstreamer                     ← DOI manifest (generated on demand; git-ignored)
│
├── <major.minor>/<runtime><java>/Dockerfile         ← generated (full edition)
├── <major.minor>/<runtime><java>-base/Dockerfile    ← generated (base edition)
│
├── test/
│   ├── lint.sh                       ← Layer 1: shellcheck, JSON schema, hadolint
│   ├── regression.sh                 ← Layer 2: generated tree up to date, no unresolved placeholders, tag consistency, golden diff
│   ├── golden-manifest.txt           ← Expected manifest without GitCommit lines (committed)
│   ├── update-golden.sh              ← Regenerates the golden and shows the diff to review
│   ├── check-release.sh              ← Publish-time gate: manifest GitCommits are on master and current
│   └── build-and-run.sh              ← Layer 3: build every image, healthcheck the full ones
│
└── docs/                             ← This file lives here
```

**Don't hand-edit files under `<major.minor>/…/Dockerfile`.** They're regenerated from `Dockerfile*.template` + `versions.json`. Any manual edit is lost the next time `./update.sh` runs.

## The generation pipeline

```mermaid
flowchart LR
    A[versions.json] --> U[update.sh]
    T1[Dockerfile.template] --> U
    T2[Dockerfile-base.template] --> U
    U --> D[Generated Dockerfiles<br/>mm/runtime+java/*]
    D --> G[generate-stackbrew-library.sh]
    G --> L[lightstreamer<br/>DOI manifest]
```

- **`update.sh`** iterates every `(version × runtime × java × variant)` combination in `versions.json`, feeds each through the appropriate template via `envsubst`, and writes one Dockerfile per combination.
- **`generate-stackbrew-library.sh`** walks the generated tree, looks up patch versions from `versions.json`, and emits the DOI-format `lightstreamer` file with the tag list and git commit hashes.
- **`lightstreamer`** is not committed. Generate it from an up-to-date `master` when you publish to DOI, because its `GitCommit` hashes depend on history and merge style.
- **`test/golden-manifest.txt`** is the committed reference: the same manifest minus the `GitCommit` lines. The regression test compares fresh generator output (also minus `GitCommit`) against it, so any unintentional tag change surfaces in the PR diff.

To update the golden after an intentional tag change, run `./test/update-golden.sh`. It rewrites the file and prints the diff; commit it only if every change is intended.

## Branching and PR flow

**All changes go on a topic branch and are merged into `master` via pull request.** Never commit directly to `master`. Every PR should:

1. Be based on the current `master`.
2. Contain only related commits (small, self-contained).
3. Leave `./test/lint.sh` and `./test/regression.sh` passing.

Once merged, follow the [Publishing to Docker Official Images](#publishing-to-docker-official-images) section below to propagate the change to [`hub.docker.com/_/lightstreamer`](https://hub.docker.com/_/lightstreamer).

The playbooks below assume you have already created a topic branch:

```bash
git switch master && git pull
git switch -c <topic-branch>            # e.g. release-7.4.9, add-java-26
```

After the playbook completes, push the branch and open a PR:

```bash
git push -u origin <topic-branch>
gh pr create --base master              # or via the GitHub UI
```

## Common changes

### 1. Bump a patch version (e.g. 7.4.8 → 7.4.9)

Most frequent change. Edit exactly one line in `versions.json`:

```json
"7.4": {
    "version": "7.4.9",                     ← change this
    "runtimes": { "jdk": ["8", "11", "17", "21", "25"] }
}
```

Then regenerate and commit:

```bash
./update.sh
./test/update-golden.sh                 # review the printed diff
./test/lint.sh && ./test/regression.sh
git add versions.json 7.4/ test/golden-manifest.txt
git commit -m "Release 7.4.9"
git push
```

### 2. Add a new Java version (e.g. Java 26 on 7.4)

Add the version to `runtimes.jdk` for the affected `major.minor`:

```json
"7.4": {
    "version": "7.4.9",
    "runtimes": { "jdk": ["8", "11", "17", "21", "25", "26"] }
}
```

Then:

```bash
./update.sh                            # creates new 7.4/jdk26[-base]/ dirs
./test/update-golden.sh                # review the printed diff
./test/lint.sh && ./test/regression.sh
git add versions.json 7.4/jdk26 7.4/jdk26-base test/golden-manifest.txt
git commit -m "Add Java 26 support to 7.4"
git push
```

If Java 26 should become the new canonical/default (the one that gets bare tags like `7.4`, `latest`, `7`), also update `default_java` at the top of [`generate-stackbrew-library.sh`](../generate-stackbrew-library.sh) and regenerate.

### 3. Add a new Lightstreamer major/minor (e.g. 7.5)

Add a new object under `.versions`:

```json
"7.5": {
    "version": "7.5.0",
    "runtimes": { "jdk": ["11", "17", "21", "25"] }
}
```

Then regenerate. Note:

- The **overall latest** (the version that earns `latest`/`<major>` tags) is determined by the LAST key in `.versions`. Put newer versions later.
- If it's a new major (e.g. `8.0`), the `<major>-…` tag for `8` will move to it automatically.

### 4. Modify a Dockerfile template

Edit `Dockerfile.template` (full edition) or `Dockerfile-base.template` (base edition). Then:

```bash
./update.sh                            # regenerates every Dockerfile
./test/lint.sh && ./test/regression.sh
./test/build-and-run.sh                # RECOMMENDED for template changes
```

The `build-and-run.sh` step is slow (10–30 min) but it's the only way to catch template bugs that only surface at `docker build` time — a broken template renders to a syntactically-fine Dockerfile that fails when Docker tries to execute it.

### 5. Change tag naming rules

Tag rules live inside the main loop of [`generate-stackbrew-library.sh`](../generate-stackbrew-library.sh) — read the inline comments there before editing.

After the change:

```bash
./test/regression.sh                   # will FAIL on golden diff if tags changed
```

If the change is intentional, the golden diff failure IS the sanity check — review the diff carefully, then regenerate the golden and commit it:

```bash
./test/update-golden.sh
```

## Testing checklist

Run in order; each layer builds on the previous:

| Layer | Command | Runtime | Purpose |
|---|---|---|---|
| Static | `./test/lint.sh` | ~1s | shellcheck + JSON schema + hadolint on generated Dockerfiles |
| Regression | `./test/regression.sh` | ~1s | generated tree up to date (else run `./update.sh`), placeholders resolved, tag consistency, golden diff |
| Build + run | `./test/build-and-run.sh` | 10–30 min | actually builds every image; runs each full-edition variant and checks `/lightstreamer/healthcheck` |

The first two should pass on every commit. The third is optional per commit but expected before opening a PR that touches templates or the generator.

### Publish-time check (not a layer)

`./test/check-release.sh` is separate from the layers above. It validates the **manifest you are about to submit to DOI**, so it runs once per publication, not per commit, and only on an up-to-date `master` (it needs `git fetch origin` first). It is run manually by whoever opens the DOI PR, as a step of the [Workflow](#workflow); nothing calls it automatically.

The layers above deliberately ignore the `GitCommit` hashes in the manifest, because they depend on history and merge style. This script is the only check on them. It fails if a hash is not reachable from `origin/master` (and `origin` must be the manifest's `GitRepo`, not a fork; set `DEFAULT_REF=<remote>/master` otherwise), if the commit lacks the image's Dockerfile, or if the image directory changed on `master` after that commit (a stale manifest). In every case the fix is to merge/fetch and regenerate the manifest.

## Commit conventions (this repository)

These apply to commits **in this source repository** — the topic-branch work from [Branching and PR flow](#branching-and-pr-flow) and the [Common changes](#common-changes) playbooks above (that's why the examples below match the `git commit -m` lines in those playbooks). They are *not* the same as the [PR title convention](#pr-title-convention) further down, which governs only the separate Docker Official Images PR.

Small commits, one topic each. Suggested subject-line format:

```
Release <patch-version>                     ← for a version bump
Add <feature> to <mm>                       ← for a matrix expansion
<Component>: <what changed>                 ← for other changes
```

Every commit should leave the repo in a "tests pass" state — no "WIP; will fix in next commit". Practically: run `./test/lint.sh && ./test/regression.sh` before every commit. `./test/regression.sh` tests your working tree; to check what you actually committed, run `./test/regression.sh --committed`, which tests `HEAD` in a clean checkout and ignores uncommitted changes.

## Publishing to Docker Official Images

To make these images visible on [`hub.docker.com/_/lightstreamer`](https://hub.docker.com/_/lightstreamer), submit a PR against [`docker-library/official-images`](https://github.com/docker-library/official-images) that updates `library/lightstreamer` with the freshly-generated manifest.

### One-time setup

```bash
# Fork docker-library/official-images on GitHub, then clone your fork locally:
git clone git@github.com:<your-user>/official-images.git
cd official-images
git remote add upstream https://github.com/docker-library/official-images.git
```

### PR title convention

Before running the [Workflow](#workflow) below, decide the PR title — you'll pass it to `gh pr create --title "…"` (the commit in the fork keeps the fixed message `Update Lightstreamer image`). DOI expects the form `<image>: <short summary>`, ideally under ~60 characters so titles don't truncate in the GitHub UI. Keep the summary minimal; details go in the PR body.

| Change | Title |
|---|---|
| Routine patch bump | `lightstreamer: 7.4.10` |
| Add a new Java version | `lightstreamer: add jdk26` |
| Add a new major/minor | `lightstreamer: 7.5.0` |
| Structural change (tag scheme, new variant family, etc.) | `lightstreamer: refactor tag scheme; add -base variant` |

Rules of thumb:

- **State the *change*, not the motivation.** `refactor tag scheme` ✅, not `improve tag discoverability` ❌.
- **Use a semicolon for two conceptually distinct changes** in one PR. Reviewers know to check each independently.
- **Omit consequences** (dependency bumps triggered by the change, etc.) — the body explains them. Keeps the title stable if the body evolves during review.
- **Reuse DOI's own vocabulary** where it exists — "refactor tag scheme", "add variant", "add architecture", "deprecate" — so the title sets the correct reviewer mental model.

### Workflow

After your source-repo change is merged into `master` (via the [Branching and PR flow](#branching-and-pr-flow) at the top of this document), generate the manifest from `master` (the file is git-ignored, so any merge style works), verify locally, then open the PR against [`docker-library/official-images`](https://github.com/docker-library/official-images) from your fork:

```bash
# In the source repo (on master, fully up to date: git fetch origin && git pull)
./generate-stackbrew-library.sh > lightstreamer
./test/check-release.sh                           # publish-time gate: DOI can build every GitCommit
./test/lint.sh && ./test/regression.sh
bashbrew --library "$(pwd)" list --build-order --uniq lightstreamer   # preview what would be built
bashbrew --library "$(pwd)" build --pull always lightstreamer         # optional but recommended — same build DOI's CI runs

# In the official-images fork
cd <path-to-official-images-fork>
git switch master && git fetch upstream && git reset --hard upstream/master
git push origin master --force-with-lease
git switch -c lightstreamer-<short-desc>          # e.g. lightstreamer-7.4.10
cp <path-to-source-repo>/lightstreamer library/lightstreamer
git add library/lightstreamer
git diff --staged                                 # sanity: only expected lines changed
git commit -m "Update Lightstreamer image"
git push origin lightstreamer-<short-desc>

gh pr create --repo docker-library/official-images --base master \
    --title "lightstreamer: <short-summary>"
```

Notes on the surprising-looking commands:

- **`./test/check-release.sh`** — the publish-time gate described under [Testing checklist](#publish-time-check-not-a-layer). Run it after generating the manifest and before copying it to the fork; if it fails, merge/`git fetch` and regenerate.
- **`git reset --hard upstream/master` + `git push --force-with-lease` on the fork's `master`** — the fork's master serves purely as a launching pad for PR branches; it should always mirror upstream. `--force-with-lease` is a safer variant of `--force` that refuses to push if someone else has updated the remote in the meantime.
- **`bashbrew --library "$(pwd)" list --build-order --uniq lightstreamer`** — prints the images the follow-up `build` will process, in dependency order. Always visible, so useful as a sanity check that the manifest parses.
- **`bashbrew --library "$(pwd)" build --pull always lightstreamer`** — `"$(pwd)"` is the source repo. Bashbrew reads the `lightstreamer` manifest from that directory and builds every block using the exact procedure DOI's CI runs. **The command is silent when every image is already built and cached locally** — that's success, not a hang. `--pull always` forces a fresh base-image pull each run, matching CI behavior and making cached-image silence rare in practice. Green here means the DOI bot will most likely be green too. Skip for trivial changes (patch bump on already-published tags); recommended for template changes, new variants, or tag-scheme rework.
- **`--library` path depends on which repo you're running from.** From the source repo, the manifest is at the top level, so `--library "$(pwd)"` is correct. From the official-images fork, the manifest lives under `library/`, so use `--library "$(pwd)/library"` instead. Without an explicit `--library`, bashbrew falls back to its built-in default (often a stale hard-coded path) and reports `unable to find a manifest named "lightstreamer"`. Alternatively, set `BASHBREW_LIBRARY` in your shell to whichever fork you use most, and drop the flag.

### Iterating on reviewer comments

If a DOI maintainer requests changes, land the fix in the source repo the normal way (topic branch → PR → tests green → merged into `master`), then update the fork's PR branch:

```bash
# In the source repo (on master, after the follow-up change has landed)
./generate-stackbrew-library.sh > lightstreamer

# In the official-images fork
cd <path-to-official-images-fork>
git switch lightstreamer-<short-desc>
cp <path-to-source-repo>/lightstreamer library/lightstreamer
git add library/lightstreamer
git commit --amend --no-edit                      # or a new commit if you prefer
git push --force-with-lease
```

The GitHub PR auto-updates and the DOI bot re-runs its checks.

### What NOT to include in the DOI PR

- Any file other than `library/lightstreamer`. No docs, no scripts, no `.github/workflows` — those live in your source repo only.
- Whitespace-only diffs or reordered blocks. Always regenerate the manifest fresh from `generate-stackbrew-library.sh` rather than hand-editing.
- Commit hashes that aren't pushed to a public branch or tag on `github.com/Lightstreamer/Docker`.

### Edge case: dry-run from a non-`master` branch

The standard flow requires merging to `master` before submitting to DOI, because DOI can only build commits that are **reachable on `github.com/Lightstreamer/Docker`**. For exceptional cases — say you want DOI maintainer feedback on a big refactor before merging it — you can point DOI at a topic branch instead, but the generator does **not** automate this; do it by hand:

1. **Push the topic branch** to `github.com/Lightstreamer/Docker` so its commits are public. (A personal fork won't do — the manifest's `GitRepo` is the canonical repo, so that's where DOI fetches from.)
2. **Add a `GitFetch` line by hand** to the generated manifest, right under `GitRepo`, so bashbrew/DOI's `naughty.sh` can locate commits that aren't on the default branch:

   ```
   GitRepo: https://github.com/Lightstreamer/Docker.git
   GitFetch: refs/heads/<topic-branch>
   ```

3. **Never submit this dry-run manifest as the final one.** `generate-stackbrew-library.sh` never emits `GitFetch`, and the line is wrong once the branch merges.

Once the refactor merges to `master`, regenerate normally: the commits are then reachable on the default branch and no `GitFetch` is needed.

## Prerequisites (host tooling)

- **bash ≥ 4** (for associative arrays, `${arr[-1]}`)
- **git ≥ 2.5** (`git worktree`, used by `regression.sh --committed`)
- **jq ≥ 1.6**
- **docker** (for `test/build-and-run.sh` only)
- **shellcheck** (recommended)
- **hadolint** (recommended)
- **envsubst** (part of gettext, usually preinstalled)
- **curl** (for `test/build-and-run.sh`'s healthcheck probe)

On Debian/Ubuntu:

```bash
sudo apt-get install -y jq shellcheck gettext-base curl
sudo wget -O /usr/local/bin/hadolint \
    https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64
sudo chmod +x /usr/local/bin/hadolint
```

## Getting help

The two generator scripts ([`update.sh`](../update.sh), [`generate-stackbrew-library.sh`](../generate-stackbrew-library.sh)) are heavily commented — read them alongside this document if a playbook step feels underspecified.

If something's unclear or a common change isn't covered here, open an issue.
