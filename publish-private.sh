#!/usr/bin/env bash
# Build all four archives on machines of the operator's own, and put them where only
# collaborators can read them.
#
# Usage:
#   ./publish-private.sh
#
# This is the whole of releasing, and it is fdk-aac-prebuilt's model: this repository — which is
# public — publishes the source of the build and no binary of it. The archives go to the
# releases of `PREBUILT_REPO` (ffmpeg.env), a private repository, and
# crates/libavcodec-hevc-prebuilt-sys/build.rs reads them back through `gh` for whoever is
# logged in to an account with access. They are built on the operator's machines rather than in
# a workflow for the same reason: a public repository's workflow artifacts can be downloaded by
# anyone with a GitHub account, and a private repository's runners are paid for by the minute.
#
# Run on Linux x86_64, with the sibling `devtools` checkout beside this one (or `DEVTOOLS_DIR`
# naming it): its remote drivers copy a tree to a machine, run this repository's ci/unix/ci.sh
# or ci/windows/ci.ps1 there, and hand back the `dist/<target>` that leaves behind. Four
# builders, at once:
#
#   here                                              linux-x86_64
#   the devtools arm64 builder (remote-lxc, `-a`)     linux-aarch64
#   $LIBAVCODEC_HEVC_PREBUILT_MACOS_HOST, or macvm    macos-arm64
#   the devtools Windows CI box                       windows-x86_64-msvc
#
# Every archive passes the gate build.yml applies, on the machine that built it: build.sh's own
# verification (licence, registry, entry points, SIMD kernels, CRT), the link, clippy, the e2e
# binary decoding bit-exactly with SIMD on and off, and check-static.sh. A release is all four or
# it does not happen.
#
# Commit and push first. What gets built is `git archive HEAD`, not this directory, so nothing
# uncommitted or ignored can reach an archive. The tag is *computed*, never typed —
# `v<ffmpeg>-<YYYYMMDDHHMMSS>-<short sha>`, the version saying what is inside, the timestamp
# when, and the hash which commit — and it is created twice: on the private repository, as the
# release holding the archives, and on this one, as the plain git tag a consumer's manifest names
# to pin the crate those archives were tested with.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=ffmpeg.env
. ./ffmpeg.env

[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] \
  || { echo "the publisher builds linux-x86_64 itself: run it on Linux x86_64, not $(uname -s)-$(uname -m)" >&2; exit 1; }
[ $# -eq 0 ] || { sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2; }

mac_host="${LIBAVCODEC_HEVC_PREBUILT_MACOS_HOST:-macvm}"
export DEVTOOLS_DIR="${DEVTOOLS_DIR:-$here/../devtools}"
[ -f "$DEVTOOLS_DIR/ci/unix/remote.sh" ] \
  || { echo "no devtools checkout at $DEVTOOLS_DIR (set DEVTOOLS_DIR)" >&2; exit 1; }
command -v pwsh >/dev/null 2>&1 || { echo "pwsh drives the Windows builder and is not on PATH" >&2; exit 1; }
command -v nasm >/dev/null 2>&1 || { echo "nasm is needed for the linux-x86_64 build here" >&2; exit 1; }

targets=(macos-arm64 linux-x86_64 linux-aarch64 windows-x86_64-msvc)

# Every asset filename is built from this value, so a typo in ffmpeg.env becomes a release of
# misnamed archives that no consumer's build.rs can find.
echo "$FFMPEG_VERSION" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  || { echo "FFMPEG_VERSION in ffmpeg.env is not a version: '$FFMPEG_VERSION'" >&2; exit 1; }
echo "$FFMPEG_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || { echo "FFMPEG_COMMIT in ffmpeg.env is not a full sha: '$FFMPEG_COMMIT'" >&2; exit 1; }

# The tag names a commit, so the archives must be that commit's and the commit must be one a
# consumer can fetch.
[ -z "$(git status --porcelain)" ] \
  || { echo "the working tree has uncommitted changes; a release is of a commit" >&2; exit 1; }
sha="$(git rev-parse HEAD)"
origin="$(git remote get-url origin)"
git fetch --quiet origin
[ -n "$(git branch -r --contains "$sha")" ] \
  || { echo "$sha is on no branch of origin; push it first" >&2; exit 1; }

# Before the builds rather than after them: twenty minutes of compiling is a poor way to learn
# that `gh` is logged in to the wrong account.
gh release list --repo "$PREBUILT_REPO" --limit 1 >/dev/null \
  || { echo "cannot read $PREBUILT_REPO: gh auth login, with an account that has access" >&2; exit 1; }

# Seconds, so that two releases on one day sort in the order they happened, and UTC, so that the
# order does not depend on whose clock it was.
stamp="$(date -u +%Y%m%d%H%M%S)-${sha:0:7}"
tag="v${FFMPEG_VERSION}-${stamp}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$work/assets"
tree="$work/tree"
logs="$here/tmp/publish-$stamp"
mkdir -p "$out" "$tree" "$logs"

# The commit, and only the commit: ignored leftovers of earlier builds (build/, dist/, the
# crate's prebuilt/ cache) stay behind.
git archive "$sha" | tar -x -C "$tree"

# builder NAME FETCH-TARGET -- DRIVER ARGS…: run the driver's `ci` on one machine, then fetch the
# target's dist/ from the workspace it left. In the background, logged per builder, because the
# four machines have nothing to wait on each other for.
pids=()
names=()
builder() {
  local name="$1" target="$2"
  shift 3
  (
    set -e
    "$@" ci
    "$@" fetch "dist/$target" "$work/dist/$target"
  ) >"$logs/$name.log" 2>&1 &
  pids+=("$!")
  names+=("$name")
  echo ">> $name: building $target (log: $logs/$name.log)"
}

builder linux-x86_64 linux-x86_64 -- "$tree/ci/unix/remote.sh"
builder linux-aarch64 linux-aarch64 -- "$tree/ci/unix/remote.sh" -a
builder macos-arm64 macos-arm64 -- "$tree/ci/unix/remote.sh" -H "$mac_host"
builder windows-x86_64-msvc windows-x86_64-msvc -- pwsh -NoLogo -NoProfile -File "$tree/ci/windows/remote.ps1"

failed=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo ">> ${names[$i]}: passed"
  else
    echo ">> ${names[$i]}: FAILED — see $logs/${names[$i]}.log" >&2
    failed=1
  fi
done
[ "$failed" = 0 ] || { echo "no release: a builder failed" >&2; exit 1; }

# Named here rather than discovered, so that a target silently missing is a failed release
# instead of a release somebody links against six months later and finds nothing for their
# platform. And each one's MANIFEST must be of this FFmpeg: a builder that fetched a stale dist/
# from an earlier run would otherwise ship it under this tag.
for target in "${targets[@]}"; do
  manifest="$work/dist/$target/MANIFEST"
  [ -f "$manifest" ] \
    || { echo "no archive for $target — refusing to publish an incomplete release" >&2; exit 1; }
  if ! grep -qx "commit $FFMPEG_COMMIT" "$manifest" || ! grep -qx "target $target" "$manifest"; then
    echo "$target's MANIFEST is not of FFmpeg $FFMPEG_COMMIT for $target" >&2
    exit 1
  fi
  tar czf "$out/libavcodec-hevc-${FFMPEG_VERSION}-${target}.tar.gz" -C "$work/dist/$target" .
done

# A corruption check, not a tamper check: it lives on the same release as the files it covers,
# so it proves a download arrived intact, not that the release is honest.
(cd "$out" && sha256sum -- *.tar.gz >SHA256SUMS)
cat "$out/SHA256SUMS"

# Draft first, and published only after the public tag is pushed: build.rs resolves `latest`, so
# a failure at any step before the last leaves a deletable draft — never a `latest` with half its
# files, or one whose source tag does not exist.
echo ">> releasing $tag on $PREBUILT_REPO (draft)"
gh release create "$tag" --repo "$PREBUILT_REPO" --draft \
  --title "FFmpeg ${FFMPEG_VERSION} libavcodec (HEVC decoder) static archives - ${stamp}" \
  --notes "Built from ${origin%.git}/commit/${sha}" \
  "$out"/SHA256SUMS "$out"/*.tar.gz

git tag "$tag" "$sha"
git push origin "refs/tags/$tag"

gh release edit "$tag" --repo "$PREBUILT_REPO" --draft=false
echo ">> published $tag"
