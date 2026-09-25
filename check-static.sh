#!/usr/bin/env bash
# Assert that a binary carries FFmpeg's HEVC decoder inside it rather than expecting to find one.
#
#   ./check-static.sh target/release/libavcodec-hevc-e2e
#
# Three questions, and they fail in different directions:
#
#   positive — is *this* libavcodec actually in there? A log message only FFmpeg's HEVC decoder
#             prints ("Two slices reporting being the first in the same frame.") and the pinned
#             version, which build.sh compiles in as `av_version_info()`. Both are looked for,
#             because a bare "9.0.2" in a binary proves nothing on its own.
#   negative — is there a *dynamic* dependency on libavcodec or libavutil as well or instead? This
#             is the one that passes every test on the build machine — where a distribution's
#             FFmpeg is often installed — and then fails on a slim runtime image, which is
#             precisely the failure this repository exists to remove.
#   no C++    — FFmpeg is C, and build.sh asserts the archives reference no C++ runtime. Reported
#             from the binary's side too, because it is the difference from libde265-prebuilt a
#             consumer moving between the two would want to see confirmed.
#
# Run in CI on every target.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bin="${1:?usage: ./check-static.sh <binary>}"
[ -f "$bin" ] || { echo "no such file: $bin" >&2; exit 1; }

# shellcheck source=ffmpeg.env
. "$here/ffmpeg.env"

fail=0

echo ">> $bin"

# `grep -a`: treat the executable as text, which is portable in a way `nm` and `strings` are not.
if grep -aq 'Two slices reporting being the first in the same frame' "$bin" && grep -aqF "${FFMPEG_VERSION}" "$bin"; then
  echo "   ok    FFmpeg's HEVC decoder, and its version ${FFMPEG_VERSION}, are compiled in"
else
  echo "   FAIL  FFmpeg's HEVC decoder strings or its version string are not in the binary — is" >&2
  echo "         libavcodec really linked, and is it the pinned version?" >&2
  fail=1
fi

case "$(uname -s)" in
  Darwin) deps="$(otool -L "$bin" | tail -n +2 || true)" ;;
  MINGW* | MSYS* | CYGWIN*)
    # `dumpbin /dependents` needs an MSVC environment this script does not set up, so the PE
    # import table is read the crude way: an imported DLL's name is stored, in ASCII, in the file.
    deps="$(grep -aoiE '[a-z0-9_.-]+\.dll' "$bin" | sort -u || true)"
    ;;
  *) deps="$(ldd "$bin" 2>/dev/null || true)" ;;
esac

if ff_deps="$(printf '%s\n' "$deps" | grep -iE 'libav(codec|util)|(^|[^a-z])av(codec|util)(-[0-9]+)?\.dll')" && [ -n "$ff_deps" ]; then
  echo "   FAIL  dynamic dependency on FFmpeg:" >&2
  printf '           %s\n' "$ff_deps" >&2
  fail=1
else
  echo "   ok    no dynamic libavcodec or libavutil dependency"
fi

cxx_deps="$(printf '%s\n' "$deps" | grep -iE 'libstdc\+\+|libc\+\+|msvcp[0-9]+' || true)"
if [ -n "$cxx_deps" ]; then
  # Not a failure of the archives — build.sh has already proved they reference no C++ — but
  # something else in the binary brought a C++ runtime, and whoever ships it should know.
  echo "   note  the binary depends on a C++ runtime, which FFmpeg does not need:"
  printf '           %s\n' "$cxx_deps"
else
  echo "   ok    no C++ runtime"
fi

exit "$fail"
