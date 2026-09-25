#!/usr/bin/env bash
# Make the HEVC streams the e2e binary decodes, and the reference each decoded frame is held to.
#
#   ./gen-testdata.sh            # rewrite testdata/*.hevc and testdata/*.sha256
#   ./gen-testdata.sh --check    # re-derive the references from the committed streams
#
# **The same streams and references as libde265-prebuilt's e2e binary, byte for byte** — copied
# from there, not re-encoded, so the two repositories hold two different decoders to one
# reference. They were encoded once, by ffmpeg's libx265 from ffmpeg's synthetic `testsrc2`
# pattern — no third-party footage — and are **committed** rather than regenerated in CI, because
# x265's output moves between its versions and the reference hashes would move with it. The
# fixture is the input; this script is the record of where it came from.
#
# The reference is a separate FFmpeg — the distribution's (Debian 13's 7.1 when these were made),
# not the pinned build this repository ships — writing one SHA-256 per decoded frame. HEVC
# decoding is exactly specified, so correct decoders agree to the bit: libde265 reproduces these
# hashes in its own repository, and the e2e binary here requires the pinned libavcodec to
# reproduce them too, with SIMD and without, threaded and not.
#
# Each stream also carries x265's decoded-picture-hash SEI (`hash=1`, MD5): the encoder's own
# reconstruction, checked in-band as the e2e binary decodes — a third witness.
#
# Needs an ffmpeg on PATH (Debian: `apt install ffmpeg`), built with libx265 for a regeneration.
# Nothing else in this repository does. A regeneration also has to be copied to
# libde265-prebuilt, or the two repositories stop testing against the same reference.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is not installed" >&2; exit 1; }

# One line per stream: name, pixel format, x265 parameters.
#
#   main     8-bit 4:2:0, the common case. Random-access GOP with B-frames (bi-prediction,
#            so every qpel/epel interpolation kernel and the weighted-average path runs), and
#            **WPP** — wavefront parallel processing, which is what lets libavcodec decode with
#            slice threads at all (frame threads work either way).
#   main10   10-bit 4:2:0, P-frames only, **three slices per picture**. The other half of the
#            decoder: high bit depth, which has its own set of FFmpeg kernels (`…_10_sse4`,
#            `…_10_avx2`, `…_10_neon`) — and slice boundaries, with SAO on. It is the stream
#            that caught upstream libde265 1.1.3 mis-decoding SAO across slice boundaries, the
#            bug that made libde265-prebuilt carry a fork; kept here as a standing check that
#            this decoder does not. x265 refuses several slices without WPP, so WPP is on here
#            too.
#
# `info=0` leaves out x265's version-and-options SEI, which would make the stream's bytes
# depend on the x265 build rather than only on what it encoded. `keyint` below the frame count
# puts a second IRAP mid-stream, so decoding restarts from a fresh reference at least once.
streams='main yuv420p crf=30:keyint=24:min-keyint=24:bframes=3:b-adapt=0:wpp=1:hash=1:info=0
main10 yuv420p10le crf=30:keyint=24:min-keyint=24:bframes=0:wpp=1:slices=3:hash=1:info=0'

# 416x240 is HEVC's own "class D" test size, and neither dimension is a multiple of the 64x64
# coding tree block, so every picture has partial CTBs on its right and bottom edges — the
# boundary handling a 64-aligned test size would never touch.
size=416x240
frames=48

reference() {
  # $1 stream, $2 pixel format. ffmpeg's native decoder (`-c:v hevc`, named so a hardware
  # decoder can never be picked), single-threaded, writing the frames as tightly packed planes
  # — Y, then U, then V, no stride padding, little-endian 16-bit samples for 10-bit — and
  # hashing each. The e2e binary packs libavcodec's planes the same way before hashing.
  ffmpeg -nostdin -hide_banner -loglevel error -threads 1 -c:v hevc -i "testdata/$1.hevc" \
    -pix_fmt "$2" -f framehash -hash sha256 - |
    awk -F', *' '!/^#/ { print $NF }'
}

if [ "${1:-}" = "--check" ]; then
  status=0
  while read -r name pix_fmt _; do
    if diff -u "testdata/$name.sha256" <(reference "$name" "$pix_fmt"); then
      echo "testdata/$name.sha256 is what ffmpeg decodes from testdata/$name.hevc"
    else
      echo "testdata/$name.sha256 does not match ffmpeg's decode of testdata/$name.hevc" >&2
      status=1
    fi
  done <<<"$streams"
  exit "$status"
fi

mkdir -p testdata
while read -r name pix_fmt params; do
  echo ">> $name ($pix_fmt, $params)"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=$size:rate=30" -frames:v "$frames" \
    -pix_fmt "$pix_fmt" -c:v libx265 -x265-params "log-level=error:$params" \
    -f hevc "testdata/$name.hevc"
  reference "$name" "$pix_fmt" > "testdata/$name.sha256"
  echo "   $(wc -c < "testdata/$name.hevc" | tr -d ' ') bytes, $(wc -l < "testdata/$name.sha256" | tr -d ' ') frames"
done <<<"$streams"
