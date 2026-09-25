#!/usr/bin/env bash
# The Linux and macOS rows of .github/workflows/build.yml, run on the machine this is — here, or
# on another box by ci/unix/remote.sh, which leaves `dist/<target>/` behind in the workspace for
# `remote.sh fetch` to bring back. When this file and the workflow disagree, the workflow is
# right and this is stale: it exists to say what CI will say before CI is asked.
#
#   Linux x86_64   linux-x86_64    (on the driving machine: `ci/unix/remote.sh`)
#   Linux aarch64  linux-aarch64   (on the arm64 build box: `ci/unix/remote.sh -a ci`)
#   macOS arm64    macos-arm64
#
# Native, not in a container, for the same reason as build.yml: `./build.sh` builds for the
# machine it runs on, and the artifact's claims are checked on that machine's own archive.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=macos-arm64 ;;
  Linux-x86_64) target=linux-x86_64 ;;
  Linux-aarch64 | Linux-arm64) target=linux-aarch64 ;;
  *)
    echo "no target of build.sh's builds on $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac
target_dir="${CARGO_TARGET_DIR:-target}"

step() { echo; echo "== $* =="; }

step "build.sh $target"
./build.sh "$target"

step "link against it"
./sync-prebuilt.sh
cargo build --offline --release --workspace

step clippy
cargo clippy --offline --release --all-targets -- -D warnings

step "end to end"
"$target_dir/release/libavcodec-hevc-e2e"
./check-static.sh "$target_dir/release/libavcodec-hevc-e2e"

# The headers-and-bindings chain, where the pinned bindgen is installed. build.yml runs it on
# every push; here it is a courtesy, and says so when it is skipped rather than passing quietly.
if command -v bindgen >/dev/null 2>&1 && [ "$(bindgen --version | awk '{print $2}')" = 0.72.1 ]; then
  step "committed headers and bindings"
  ./sync-prebuilt.sh --check
else
  step "committed headers and bindings: skipped (bindgen 0.72.1 is not installed here)"
fi

echo
echo "all steps passed for $target"
