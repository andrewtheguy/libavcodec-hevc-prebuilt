#!/usr/bin/env bash
# Regenerate the bindings for *this platform family* from the committed FFmpeg headers.
#
#   ./gen-bindings.sh            # rewrite src/bindings.rs, or src/bindings_windows.rs on Windows
#   ./gen-bindings.sh --check    # fail if that file is not what the headers say
#
# Why generated and committed rather than generated at build time: bindgen needs libclang, and
# a `-sys` crate whose entire selling point is that a consumer needs no C toolchain cannot then
# require an LLVM installation to build.
#
# One file for macOS and both Linux architectures, which holds only because of two decisions
# below: every C integer is emitted as an alias each target resolves for itself, and the five
# functions that take a `va_list` are left out (see the blocklist). **Windows is a second file**:
# a C enum is always `int` to MSVC, where clang elsewhere types an enum with no negative values
# `unsigned` — only an alias, but one `--check` would report as drift on every run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../ffmpeg.env
. ../../ffmpeg.env

# Pinned, because bindgen's output is not stable across its own versions. An unpinned generator
# turns `--check` into a test of which bindgen the runner happened to install.
BINDGEN_VERSION=0.72.1

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) out=src/bindings_windows.rs; platform=windows ;;
  *) out=src/bindings.rs; platform=unix ;;
esac

command -v bindgen >/dev/null 2>&1 || {
  echo "bindgen is not installed. cargo install bindgen-cli --version $BINDGEN_VERSION --locked" >&2
  exit 1
}
actual_version="$(bindgen --version | awk '{print $2}')"
[ "$actual_version" = "$BINDGEN_VERSION" ] || {
  echo "bindgen $actual_version is installed but this file is generated with $BINDGEN_VERSION" >&2
  echo "  cargo install bindgen-cli --version $BINDGEN_VERSION --locked --force" >&2
  exit 1
}

# LF regardless of where it was made: on Windows rustfmt writes CRLF. Then the anonymous enums
# renumbered — see renumber_anonymous.
generate() { generate_raw | tr -d '\r' | renumber_anonymous; }

# bindgen names each top-level anonymous enum `_bindgen_ty_<n>` with one counter across *every*
# header it parsed — the system ones it then filters out included. Measured: glibc declares one
# before libavutil does and macOS's SDK does not, so the same FFmpeg enum came out `_bindgen_ty_2`
# on Linux and `_bindgen_ty_1` on macOS, and `--check` failed on one of them whichever generated
# the file. Renumbered here in order of first appearance, which depends only on FFmpeg's headers.
# Only whole identifiers: `AVChannelLayout__bindgen_ty_1` (a struct's own anonymous member,
# numbered per struct) is preceded by an identifier character and left alone. Plain POSIX awk,
# because this runs under BSD awk on macOS and MSYS2's on Windows.
renumber_anonymous() {
  awk '
    {
      out = ""; rest = $0
      while (match(rest, /_bindgen_ty_[0-9]+/)) {
        pre = substr(rest, 1, RSTART - 1)
        token = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        before = pre != "" ? substr(pre, length(pre), 1) : substr(out, length(out), 1)
        if (before ~ /[A-Za-z0-9_]/) { out = out pre token; continue }
        if (!(token in renamed)) renamed[token] = "_bindgen_ty_" (++count)
        out = out pre renamed[token]
      }
      print out rest
    }'
}
generate_raw() {
  # Layout checks kept — no `--no-layout-tests`. They are what makes committing *one*
  # bindings.rs for three targets an assertion rather than an assumption: bindgen 0.72 emits them
  # as `const _: () = { … }` blocks that fail at **compile** time, so a consumer on a target where
  # AVFrame or AVCodecContext packs differently cannot build at all.
  #
  # `--default-enum-style consts`: FFmpeg's enums (AVPixelFormat, AVCodecID, AVDiscard) grow
  # between releases, and a Rust enum holding an unlisted discriminant is undefined behaviour; a
  # constant is a number.
  #
  # **The va_list functions are blocklisted**, and with them the type. `va_list` is a different
  # type on each target this one file covers — a one-element array of `__va_list_tag` on x86_64
  # Linux, a five-field struct on aarch64 Linux, a `char *` on Apple — so binding it would make
  # the file correct on one of them (macOS adds its own `__darwin_va_list` alias). What goes: `av_vlog`, `av_log_set_callback` and its
  # default, and `av_log_format_line{,2}`, i.e. installing a custom log callback. What stays:
  # `av_log_set_level` (all a consumer usually wants) and the variadic `av_log` itself.
  #
  # `--rust-target 1.81`: from 1.82 bindgen emits `unsafe extern "C"` blocks, which do not parse
  # on an older compiler; this is the flag that decides the crate's MSRV.
  #
  # `MSYS2_ARG_CONV_EXCL`: bindgen is a native Windows program, and MSYS2 rewrites arguments
  # that look like POSIX paths on the way to one.
  MSYS2_ARG_CONV_EXCL='*' bindgen wrapper.h \
    --rust-target 1.81 \
    --allowlist-file '.*[/\\]libav(codec|util)[/\\].*' \
    --blocklist-function 'av_vlog|av_log_set_callback|av_log_default_callback|av_log_format_line2?' \
    --blocklist-type 'va_list|__gnuc_va_list|__darwin_va_list|__builtin_va_list|__va_list_tag' \
    --default-enum-style consts \
    --no-doc-comments \
    --raw-line "// @generated by gen-bindings.sh from the FFmpeg $FFMPEG_VERSION headers in include/ — do" \
    --raw-line "// not edit. Regenerate with bindgen $BINDGEN_VERSION on a $platform host." \
    --raw-line "//" \
    --raw-line "// \`--allowlist-file\` restricts this to items declared by libavcodec's and libavutil's own" \
    --raw-line "// headers. Without it the output also carries whatever <stdint.h> and <stdio.h> declare on" \
    --raw-line "// the generating machine, which is one libc's idea of them." \
    --raw-line "#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case)]" \
    -- -I include
}

if [ "${1:-}" = "--check" ]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  generate >"$tmp"
  if diff -u --strip-trailing-cr "$out" "$tmp"; then
    echo "$out matches the committed FFmpeg $FFMPEG_VERSION headers"
    exit 0
  fi
  echo "$out is stale — run gen-bindings.sh" >&2
  exit 1
fi

# Generated beside the target and renamed onto it: a `> "$out"` would truncate the committed
# bindings before bindgen runs, and a failed generation would leave an empty file.
tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
generate >"$tmp"
chmod 644 "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "wrote $out ($(wc -l <"$out" | tr -d ' ') lines from FFmpeg $FFMPEG_VERSION)"
