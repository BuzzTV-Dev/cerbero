#!/bin/sh
# Builds the gstreamer branch our Android build checks out: origin/1.28 plus the
# patches in recipes/gstreamer-1.0/.
#
# Why a branch instead of a recipe `patches` list: every GStreamer recipe shares
# one checkout of the monorepo (recipes/custom.py), and cerbero's git extract
# applies a recipe's patches with `git am`, which commits. HEAD then no longer
# matches the recipe commit, so the next patch-less sibling recipe -- gst-plugins-base,
# gst-plugins-bad, ... -- takes the `shutil.rmtree(src_dir)` path in
# Git.extract_impl() and re-checks-out a clean tree, silently dropping the patch
# for everything built after gstreamer-1.0 itself. Pinning all of them to a
# pre-patched commit via `recipes_commits` avoids that entirely.
#
# Idempotent: re-run after adding a patch or after upstream 1.28 moves.
set -eu

BRANCH="buzztv-1.28"
BASE="origin/1.28"

CERBERO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="${CERBERO_DIR}/recipes/gstreamer-1.0"
# Where cerbero keeps the shared clone. Pass the path as $1, or set
# CERBERO_SOURCES, when the build does not use the default home_dir.
REPO="${1:-${CERBERO_SOURCES:-${HOME}/cerbero/sources/local}/gstreamer-1.0}"

if [ ! -d "${REPO}/.git" ]; then
    echo "No gstreamer clone at ${REPO}." >&2
    echo "Run 'cerbero fetch gstreamer-1.0' first, then pass the clone's path as" >&2
    echo "\$1 or set CERBERO_SOURCES to the directory holding it." >&2
    exit 1
fi

git -C "${REPO}" fetch --quiet origin
BASE_SHA="$(git -C "${REPO}" rev-parse "${BASE}")"

WORKTREE="$(mktemp -d)"
cleanup() {
    git -C "${REPO}" worktree remove --force "${WORKTREE}" 2>/dev/null || true
    git -C "${REPO}" worktree prune 2>/dev/null || true
    rm -rf "${WORKTREE}"
}
trap cleanup EXIT

# -B so a stale branch from an earlier run is reset to the current base.
git -C "${REPO}" worktree add --quiet --detach "${WORKTREE}" "${BASE_SHA}"
git -C "${WORKTREE}" checkout --quiet -B "${BRANCH}" "${BASE_SHA}"

for patch in "${PATCH_DIR}"/*.patch; do
    [ -e "${patch}" ] || continue
    echo "applying $(basename "${patch}")"
    git -C "${WORKTREE}" am --ignore-whitespace "${patch}"
done

echo "${BRANCH} = ${BASE} (${BASE_SHA}) + $(git -C "${REPO}" rev-list --count "${BASE_SHA}..${BRANCH}") patch(es)"
git -C "${REPO}" log --oneline "${BASE_SHA}..${BRANCH}"
