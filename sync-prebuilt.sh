#!/usr/bin/env bash
# Connect the shell half of this repo to the Rust half.
#
# Usage:
#   ./sync-prebuilt.sh              copy dist/* into the crate's prebuilt/ cache
#   ./sync-prebuilt.sh --headers    refresh the committed headers and the generated bindings
#   ./sync-prebuilt.sh --check      verify the committed headers and bindings
#   ./sync-prebuilt.sh --fetch      download the latest private release's archives into prebuilt/
#
# Neither `prebuilt/` nor `dist/` is committed — see .gitignore. Two things *are*:
#
#   include/libavcodec/, include/libavutil/
#                      the public headers exactly as FFmpeg's own `make install-headers`
#                      installs them from the pinned commit, including the two it generates
#                      (libavutil/avconfig.h and libavutil/ffversion.h).
#   src/bindings.rs    generated *from* those headers by gen-bindings.sh — and
#   src/bindings_windows.rs, the same thing generated on Windows (see gen-bindings.sh).
#
# Which is a chain: ffmpeg.env pins a commit, the commit gates the checkout, the checkout is
# where the headers come from, and the headers are where the bindings come from. `--check`
# checks every link and CI runs it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=ffmpeg.env
. ./ffmpeg.env
# shellcheck source=source.sh
. ./source.sh

crate=crates/libavcodec-hevc-prebuilt-sys
prebuilt="$crate/prebuilt"
header_dirs=(libavcodec libavutil)

# Every target build.sh knows how to make.
targets=(macos-arm64 linux-x86_64 linux-aarch64 windows-x86_64-msvc)

# Install the public headers of the pinned tree into $1 (holding libavcodec/ and libavutil/),
# by asking FFmpeg's own build: configure with the same feature switches the archives use, then
# `make install-headers`. No compiling — configure renders avconfig.h, and the one make rule
# renders ffversion.h with the same REVISION build.sh passes.
#
# `--disable-x86asm` so this runs where nasm is not installed; it changes nothing that is
# installed. (`--disable-asm` would: it turns AV_HAVE_FAST_UNALIGNED off in avconfig.h — measured —
# which is why it is not used.) --check also diffs this set against what `make install` put in
# any artifact in dist/, which is what would catch a target whose avconfig.h differs.
stage_headers() {
  local dest="$1" dir="build/headers"
  rm -rf "$dir"
  mkdir -p "$dir"
  # On Windows, MSVC: an MSYS2 shell has no other compiler for configure's probes.
  windows_toolchain
  (cd "$dir" && "../ffmpeg-${FFMPEG_VERSION}/configure" "${FFMPEG_FEATURE_ARGS[@]}" \
    ${FFMPEG_TOOLCHAIN_ARGS[@]+"${FFMPEG_TOOLCHAIN_ARGS[@]}"} --disable-x86asm) >"$dir/configure.log" 2>&1 || {
    tail -20 "$dir/configure.log" >&2
    return 1
  }
  make -C "$dir" install-headers DESTDIR="$here/$dir/stage" "REVISION=$FFMPEG_VERSION" >/dev/null
  mkdir -p "$dest"
  local sub
  for sub in "${header_dirs[@]}"; do
    cp -R "$dir/stage/usr/local/include/$sub" "$dest/$sub"
  done
  for header in "$dest"/*/*.h; do to_lf "$header"; done
}

case "${1:-}" in
  --headers | --check)
    ensure_source
    src="build/ffmpeg-${FFMPEG_VERSION}"

    if [ "$1" = "--headers" ]; then
      for sub in "${header_dirs[@]}"; do rm -rf "${crate:?}/include/$sub"; done
      stage_headers "$crate/include"
      # FFmpeg's licence notice and the LGPL text, from the same verified checkout, at the
      # repository root where anyone looks first.
      cp "$src/LICENSE.md" LICENSE.md
      cp "$src/COPYING.LGPLv2.1" COPYING.LGPLv2.1
      echo ">> $crate/include is now FFmpeg $FFMPEG_VERSION's public libavcodec and libavutil headers"
      (cd "$crate" && ./gen-bindings.sh)
      exit 0
    fi

    echo ">> comparing the committed headers against FFmpeg $FFMPEG_VERSION"
    # Staged into a directory of nothing but those headers, then compared as directories: one
    # `diff -r` covers changed, missing *and* extra files, and an extra one matters because the
    # bindings are generated from whatever is sitting there.
    staged="$(mktemp -d)"
    trap 'rm -rf "$staged"' EXIT
    stage_headers "$staged"
    if diff -r "$staged" "$crate/include" >/dev/null 2>&1; then
      echo "   $(find "$staged" -type f | wc -l | tr -d ' ') headers, byte-identical"
    else
      echo "the committed headers are not FFmpeg $FFMPEG_VERSION's — run --headers" >&2
      diff -r "$staged" "$crate/include" | head -30 >&2
      exit 1
    fi

    # The membership half: what each built artifact's own `make install` produced, against what
    # is committed. The licence files travel in the artifact's include/ but are not headers.
    checked=0
    for installed in dist/*/include; do
      [ -d "$installed" ] || continue
      if ! diff -r -x LICENSE.md -x COPYING.LGPLv2.1 "$installed" "$crate/include" >/dev/null 2>&1; then
        echo "$installed does not match the committed headers" >&2
        diff -r -x LICENSE.md -x COPYING.LGPLv2.1 "$installed" "$crate/include" | head -30 >&2
        exit 1
      fi
      checked=$((checked + 1))
    done
    if [ "$checked" -gt 0 ]; then
      echo "   and identical to what make install produced in $checked built target(s)"
    else
      echo "   note: nothing in dist/, so the installed-set check did not run"
    fi

    if ! diff -q "$src/LICENSE.md" LICENSE.md >/dev/null || ! diff -q "$src/COPYING.LGPLv2.1" COPYING.LGPLv2.1 >/dev/null; then
      echo "LICENSE.md or COPYING.LGPLv2.1 is not the pinned checkout's — run --headers" >&2
      exit 1
    fi
    echo "   LICENSE.md and COPYING.LGPLv2.1 match"

    (cd "$crate" && ./gen-bindings.sh --check)
    ;;

  --fetch)
    # Whatever the latest release holds — the same thing build.rs would fetch, including the
    # SHA256SUMS check. Through `gh`, as build.rs does, because the archive repository is private.
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    gh release download --repo "$PREBUILT_REPO" --dir "$tmp" \
      --pattern SHA256SUMS --pattern "libavcodec-hevc-${FFMPEG_VERSION}-*.tar.gz"

    for target in "${targets[@]}"; do
      asset="libavcodec-hevc-${FFMPEG_VERSION}-${target}.tar.gz"
      [ -f "$tmp/$asset" ] || { echo "the latest release has no $asset" >&2; exit 1; }
      echo ">> $asset"

      expected="$(awk -v a="$asset" '$2 == a || $2 == "./" a { print $1 }' "$tmp/SHA256SUMS")"
      [ -n "$expected" ] || { echo "SHA256SUMS does not list $asset" >&2; exit 1; }
      actual="$(sha256_of "$tmp/$asset")"
      [ "$actual" = "$expected" ] || {
        echo "checksum mismatch for $asset" >&2
        echo "  SHA256SUMS says $expected" >&2
        echo "  the download is $actual" >&2
        exit 1
      }

      rm -rf "${prebuilt:?}/${target:?}"
      mkdir -p "$prebuilt/$target"
      tar xzf "$tmp/$asset" -C "$prebuilt/$target"
    done
    ;;

  "")
    # The local loop: whatever ./build.sh has produced becomes what cargo links, with no
    # release and no network in the picture at all.
    [ -d dist ] || { echo "nothing in dist/ — run ./build.sh <target> first" >&2; exit 1; }
    found=0
    for dir in dist/*/; do
      target="$(basename "$dir")"
      [ -f "$dir/MANIFEST" ] || continue
      rm -rf "${prebuilt:?}/${target:?}"
      mkdir -p "$prebuilt"
      cp -R "$dir" "$prebuilt/$target"
      echo ">> $target ($(sed -n 's/^cpu_floor //p' "$dir/MANIFEST"))"
      found=$((found + 1))
    done
    [ "$found" -gt 0 ] || { echo "no built targets in dist/" >&2; exit 1; }
    echo ">> $found target(s) in $prebuilt — cargo will use these before any release"
    ;;

  *)
    sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
    ;;
esac
