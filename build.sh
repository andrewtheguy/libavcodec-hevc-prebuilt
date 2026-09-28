#!/usr/bin/env bash
# Build one static libavcodec + libavutil holding FFmpeg's HEVC decoder and parser and nothing
# else, with the claims about it verified rather than assumed.
#
# Usage:
#   ./build.sh <target>
#
# Targets:
#   macos-arm64          libavcodec.a libavutil.a  (Apple silicon, deployment target 14.0; NEON, i8mm at run time)
#   linux-x86_64         libavcodec.a libavutil.a  (x86-64 baseline; SSE2..AVX2 dispatched at run time)
#   linux-aarch64        libavcodec.a libavutil.a  (ARMv8-A baseline; NEON, i8mm at run time)
#   windows-x86_64-msvc  avcodec.lib avutil.lib    (x86-64 baseline, same kernels as Linux; dynamic CRT)
#
# Output: dist/<target>/{lib,include}/… plus a MANIFEST naming the version, the commit, the
# checksums, the configure line, the CPU floor, the SIMD configuration and kernels actually in
# the archive, and — measured rather than assumed — which system libraries the archives need.
#
# **FFmpeg's own `configure` + `make`.** It is what knows which of libavcodec's files the HEVC
# decoder needs, which assembly goes to nasm and which to the C compiler, and how each kernel is
# reached through runtime CPU detection. Building it here once is what frees every consumer from
# needing nasm, a configure shell or a C toolchain at all.
#
# The Windows target is FFmpeg's MSVC toolchain (`--toolchain=msvc`: cl, link, lib), driven from
# an MSYS2 bash (make, nasm) inside a VS developer environment — the same arrangement as
# libvpx-prebuilt's Windows build, and for the same reason: a MinGW `libavcodec.a` would be the
# easier build and the wrong artifact, its objects reaching into libgcc and the MinGW CRT, which an
# MSVC link of a Rust binary does not carry.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=ffmpeg.env
. ./ffmpeg.env
# shellcheck source=source.sh
. ./source.sh

target="${1:-}"
[ -n "$target" ] || {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 1
}

src="$here/build/ffmpeg-${FFMPEG_VERSION}"
out="$here/dist/$target"

# ---------------------------------------------------------------- source

ensure_source

# ---------------------------------------------------------------- configure

# Nothing from the environment reaches the compiler: FFmpeg's configure appends `CFLAGS`,
# `LDFLAGS` and friends from the environment, so a shell with `-march=native` exported would
# floor this archive to the builder's CPU from an unchanged script.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ASFLAGS

# What is in the library (source.sh), plus what every target shares.
#
# `--disable-debug`: no `-g`. The archives are release artifacts, a debug build of them is
# several times the size, and on MSVC `-Z7` would embed CodeView in every object.
#
# `--prefix` is *not* in here, and neither is any other path. FFmpeg compiles its configure line
# into the library — `avcodec_configuration()` returns it — so a path in it would be this
# machine's, in every consumer's binary, and would make two identical builds on two machines
# differ. The install below goes through `DESTDIR` under the default prefix instead.
configure_args=("${FFMPEG_FEATURE_ARGS[@]}" --enable-static --disable-shared --disable-debug)

floor='unset'
deployment_target=''
msvc=0
# The archives' names follow the platform's convention — and, for MSVC, rustc's:
# `static=avcodec` resolves to `avcodec.lib` there and to `libavcodec.a` everywhere else.
# FFmpeg's MSVC toolchain installs them under exactly those names (measured), so the collect step
# copies without renaming.
lib_prefix=lib
lib_suffix=.a
# A path as a native Windows program reads it — `C:/…` under MSYS2, where llvm-nm and
# llvm-readobj are native executables. Identity everywhere else.
np() { if [ "$msvc" = 1 ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

case "$target" in
  macos-arm64)
    # The deployment target through the environment rather than `--extra-cflags`: clang reads
    # MACOSX_DEPLOYMENT_TARGET for *every* invocation, including the ones FFmpeg's Makefile makes
    # to assemble the NEON `.S` files, which do not all see the extra C flags. Read back off every
    # member below rather than trusted.
    #
    # 14.0, the oldest macOS supported. It also settles the hwaccel's `__builtin_available(macOS
    # 12.0, …)` checks at compile time; below 12.0 clang compiles each into a call to
    # `__isPlatformVersionAtLeast`, compiler-rt's runtime half of `@available`. A Rust link has no
    # compiler-rt: std defines the symbol weakly, says not to rely on it, and a thin-LTO link drops
    # it before the linker meets the archive's reference — measured, an undefined-symbol failure in
    # a consumer's release build. So no availability check is left to run; asserted below.
    deployment_target=14.0
    export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
    # VideoToolbox's HEVC hwaccel, the one hwaccel in any archive: the decoder above hands its
    # pictures to the Mac's media engine when a consumer gives the context a VideoToolbox device,
    # and decodes on the CPU when it does not. VideoToolbox and the frameworks it needs are part
    # of every macOS, so what it adds to a consumer's link is Apple's own frameworks — measured
    # below, like the system libraries — and never a library the build machine happened to have.
    configure_args+=(--enable-pthreads --enable-videotoolbox --enable-hwaccel=hevc_videotoolbox)
    floor='armv8-a (NEON is baseline; i8mm kernels dispatched at run time)'
    ;;
  linux-x86_64)
    # **No CPU floor, deliberately** — the same argument as libvpx-prebuilt and
    # libde265-prebuilt. FFmpeg's x86 kernels are nasm assembly, one function per instruction
    # set (`ff_hevc_put_qpel_h8_8_sse4`, `…_avx2`), and `ff_hevc_dsp_init_x86` installs whichever
    # the CPU supports from `av_get_cpu_flags()` — CPUID, at run time
    # (CONFIG_RUNTIME_CPUDETECT, asserted below). A `-march` floor could not decide which kernel
    # runs; it could only cost the archive every machine below it.
    #
    # `--enable-pic` because Rust links position-independent executables by default, and a
    # non-PIC object in a PIE is a link error (`relocation R_X86_64_32 … recompile with -fPIC`).
    configure_args+=(--enable-pthreads --enable-pic)
    floor='x86-64 baseline (runtime CPU detection: sse2..avx2 kernels dispatched at run time)'
    ;;
  linux-aarch64)
    # NEON is mandatory in ARMv8-A, so FFmpeg's NEON kernels are baseline code here; the i8mm
    # ones (the 8-bit qpel/epel filters) are chosen at run time from getauxval, like the x86
    # kernels. FFmpeg 9.0.2 has no dotprod HEVC kernels; configure's HAVE_DOTPROD is for others.
    configure_args+=(--enable-pthreads --enable-pic)
    floor='armv8-a (NEON is baseline; i8mm kernels dispatched at run time)'
    ;;
  windows-x86_64-msvc)
    # **`-MD`: the dynamic CRT.** Rust's MSVC targets link it, and FFmpeg's MSVC toolchain names
    # no runtime at all, which cl takes as `/MT` — the static CRT, and the mismatch that fails a
    # consumer's final link. Read back off the objects' `/DEFAULTLIB` directives below.
    #
    # Win32 threads rather than pthreads: FFmpeg's own `w32pthreads.h` shim, no library needed.
    #
    # **`-Brepro`**: cl otherwise stamps every object's COFF header with the time it was compiled,
    # which was the only difference between two builds of one commit (see "Reproducibility" below).
    configure_args+=(--enable-w32threads "--extra-cflags=-MD -Brepro")
    floor='x86-64 baseline (runtime CPU detection: sse2..avx2 kernels dispatched at run time)'
    lib_prefix=''
    lib_suffix=.lib
    msvc=1
    # MSVC's cl, link and lib, with `link` put ahead of MSYS2's coreutils one (see source.sh).
    windows_toolchain
    configure_args+=("${FFMPEG_TOOLCHAIN_ARGS[@]}")
    ;;
  *)
    echo "unknown target: $target" >&2
    exit 1
    ;;
esac

# x86_64 needs nasm for every SIMD kernel. FFmpeg's configure refuses to continue without it
# (unless told `--disable-x86asm`), which is the loud failure wanted — checked here first only
# so the message says what to install.
case "$target" in
  linux-x86_64 | windows-x86_64-msvc)
    command -v nasm >/dev/null 2>&1 || {
      echo "nasm is not installed, and FFmpeg needs it for every x86_64 SIMD kernel." >&2
      echo "  apt-get install nasm   (MSYS2: pacman -S nasm)" >&2
      exit 1
    }
    ;;
esac

# Reproducibility, and what it does and does not cover.
#
# FFmpeg compiles no `__DATE__` or `__TIME__`. Its version string comes from ffbuild/version.sh,
# which in a git checkout asks `git describe` — and in this one-commit-deep checkout, with no tags,
# gets an abbreviated hash whose length depends on the git that ran it. `REVISION` on make's
# command line overrides that with the release number, which is what `av_version_info()` then
# returns and what the e2e binary asserts. configure itself already asks GNU ar for its
# deterministic mode (`rcD`) where ar has one.
#
# MSVC's tools stamp the time into their output by default, and two Windows builds of one commit
# differed in exactly that and nothing else: each object's COFF `TimeDateStamp` and each archive
# member's header date. Three switches remove it: cl's `-Brepro` (with `-MD` above), nasm's
# `--reproducible` — through `NASMENV`, which nasm reads as extra options, because setting
# `X86ASMFLAGS` on make's command line would override the include flags common.mak appends to
# it — and lib's `-Brepro`, through `ARFLAGS`, which only library.mak reads.
make_vars=("REVISION=$FFMPEG_VERSION")
if [ "$msvc" = 1 ]; then
  make_vars+=("ARFLAGS=-nologo -Brepro")
  export NASMENV=--reproducible
fi

rm -rf "$out" "build/$target"
mkdir -p "build/$target"

echo ">> configuring FFmpeg ${FFMPEG_VERSION} for $target"
# Run from the build directory, so the source tree stays clean (source.sh checks). The source
# path is relative — `../ffmpeg-<version>` — because configure records it in the generated
# makefiles, and relative keeps it identical on every machine.
(cd "build/$target" && "../ffmpeg-${FFMPEG_VERSION}/configure" "${configure_args[@]}") >"build/$target/configure.log" 2>&1 || {
  tail -30 "build/$target/configure.log" >&2
  [ -f "build/$target/ffbuild/config.log" ] && tail -30 "build/$target/ffbuild/config.log" >&2
  exit 1
}

jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
echo ">> building"
make -C "build/$target" -j"$jobs" "${make_vars[@]}" >"build/$target/make.log" 2>&1 || {
  tail -40 "build/$target/make.log" >&2
  exit 1
}
make -C "build/$target" install DESTDIR="$here/build/$target/stage" "${make_vars[@]}" >/dev/null

# ---------------------------------------------------------------- collect

stage="build/$target/stage/usr/local"
mkdir -p "$out/lib"
libs=()
for name in avcodec avutil; do
  cp "$stage/lib/$lib_prefix$name$lib_suffix" "$out/lib/$lib_prefix$name$lib_suffix"
  libs+=("$out/lib/$lib_prefix$name$lib_suffix")
done
# The whole installed header set, not a hand-picked list: FFmpeg's `install-headers` decides what
# is public, including the two it generates (libavutil/avconfig.h, libavutil/ffversion.h), and
# sync-prebuilt.sh --check compares the committed copies against exactly this.
cp -R "$stage/include" "$out/include"
for header in "$out"/include/*/*.h; do to_lf "$header"; done
# FFmpeg's licence, from the same verified checkout. This configuration is LGPL-2.1-or-later —
# configure says so (checked below) — and whoever links these archives distributes FFmpeg and
# has obligations the README describes.
cp "$src/LICENSE.md" "$src/COPYING.LGPLv2.1" "$out/include/"

# ---------------------------------------------------------------- verify

config_h="build/$target/config.h"
config_mak="build/$target/ffbuild/config.mak"
# Since FFmpeg 6.1 the component switches (decoders, parsers, …) live in their own header.
components_h="build/$target/config_components.h"

echo ">> verifying the configuration"
# The licence first, since it is the one property a consumer cannot fix afterwards: anything that
# pulled in a GPL or non-free component would make every binary linking this GPL.
license="$(sed -n 's/^#define FFMPEG_LICENSE "\(.*\)"$/\1/p' "$config_h")"
[ "$license" = "LGPL version 2.1 or later" ] || {
  echo "configure says the licence is '$license', not LGPL version 2.1 or later" >&2
  exit 1
}
echo "   licence: $license"

# Then what `--disable-everything` left: exactly one decoder, one parser, no encoder or bsf, and
# no hwaccel but VideoToolbox's HEVC one on macOS. Read from config_components.h — FFmpeg's own
# statement of what it compiled — and then again from the archive below.
case "$target" in
  macos-*) want_hwaccel=HEVC_VIDEOTOOLBOX ;;
  *) want_hwaccel='' ;;
esac
enabled() { { grep -E "^#define CONFIG_[A-Z0-9_]+_$1 1$" "$components_h" || true; } | sed -E "s/^#define CONFIG_([A-Z0-9_]+)_$1 1$/\1/" | tr '\n' ' ' | sed 's/ $//'; }
for kind in DECODER PARSER ENCODER BSF HWACCEL; do
  got="$(enabled "$kind")"
  case "$kind" in
    DECODER | PARSER) want=HEVC ;;
    HWACCEL) want="$want_hwaccel" ;;
    *) want='' ;;
  esac
  [ "$got" = "$want" ] || {
    echo "config.h enables ${kind}s '${got}', expected '${want}'" >&2
    exit 1
  }
done
# configure drops a component whose dependencies it cannot find with no more than a line in its
# log, so the hwaccel's library switch is asserted too: without it the component above is dead.
if [ -n "$want_hwaccel" ] && ! grep -qE '^#define CONFIG_VIDEOTOOLBOX 1$' "$config_h"; then
  echo "CONFIG_VIDEOTOOLBOX is off — configure dropped VideoToolbox" >&2
  exit 1
fi
echo "   decoder: hevc   parser: hevc   encoders, bsfs: none   hwaccels: ${want_hwaccel:-none}"

# The SIMD configuration FFmpeg settled on. configure turns an instruction set *off* with no
# more than a line in its output when a probe fails — an old nasm without AVX-512 support, an
# assembler that cannot do i8mm — so the flags that matter here are asserted, not echoed.
have() { grep -qE "^#define $1 1$" "$config_h"; }
have CONFIG_RUNTIME_CPUDETECT || { echo "CONFIG_RUNTIME_CPUDETECT is off — the kernels would be chosen at build time" >&2; exit 1; }
case "$target" in
  linux-x86_64 | windows-x86_64-msvc) required='HAVE_X86ASM HAVE_SSE2_EXTERNAL HAVE_SSSE3_EXTERNAL HAVE_SSE4_EXTERNAL HAVE_AVX_EXTERNAL HAVE_AVX2_EXTERNAL' ;;
  *) required='HAVE_NEON HAVE_I8MM' ;;
esac
for flag in $required; do
  have "$flag" || { echo "$flag is off in config.h — configure dropped those kernels" >&2; exit 1; }
done
# Everything SIMD-shaped that is on, for the MANIFEST, whether or not it was required.
simd_config="$(grep -E '^#define HAVE_(X86ASM|MMX|MMXEXT|SSE[0-9]*|SSSE3|AVX[0-9A-Z]*|FMA[34]|NEON|DOTPROD|I8MM|SVE[0-9]*)(_EXTERNAL)? 1$' "$config_h" |
  awk '{print $2}' | sed 's/^HAVE_//; s/_EXTERNAL$//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
echo "   runtime CPU detection, and: $simd_config"

if [ "$msvc" = 1 ]; then
  echo ">> verifying the archives hold object code, not LTCG blobs"
  # Every member of both, not a sample: `/GL` is per translation unit. llvm-readobj prints one
  # `Format:` line per object it can parse and an error per one it cannot.
  for lib in "${libs[@]}"; do
    members="$(llvm-ar t "$(np "$lib")" | wc -l | tr -d ' ')"
    headers="$(llvm-readobj --file-headers "$(np "$lib")" 2>"build/$target/readobj.err" | grep -c '^Format: COFF-x86-64$' || true)"
    if [ -s "build/$target/readobj.err" ] || [ "$headers" != "$members" ]; then
      echo "$(basename "$lib"): $headers of $members members are x86-64 COFF objects" >&2
      head -3 "build/$target/readobj.err" >&2 || true
      exit 1
    fi
    echo "   $(basename "$lib"): $members members, all COFF-x86-64"
  done
  rm -f "build/$target/readobj.err"
fi

case "$target" in
  windows-*)
    command -v llvm-nm >/dev/null 2>&1 || {
      echo "llvm-nm is not on PATH — install LLVM and put its bin directory on PATH" >&2
      exit 1
    }
    nm_tool=llvm-nm
    ;;
  *) nm_tool="nm" ;;
esac
# `type name` pairs, member headers dropped. No `2>/dev/null || true`: an nm that cannot read an
# archive would produce an empty list, and every check below would then report a *missing*
# symbol — a measurement failure wearing the costume of a build failure.
#
# Apple's nm prints an undefined symbol as its bare name, with no `U` column, which is read as one:
# dropping one-field lines instead left the macOS list empty, and every measurement of it vacuous.
list_symbols() {
  # $1: --defined-only or --undefined-only; $2: the archive
  "$nm_tool" "$1" "$(np "$2")" | awk '!/:$/ && NF >= 2 { print $(NF-1), $NF } !/:$/ && NF == 1 { print "U", $1 }'
}
avcodec_defined="$(list_symbols --defined-only "${libs[0]}")" || { echo "$nm_tool could not read ${libs[0]}" >&2; exit 1; }
avutil_defined="$(list_symbols --defined-only "${libs[1]}")" || { echo "$nm_tool could not read ${libs[1]}" >&2; exit 1; }

echo ">> verifying the entry points are in the archives"
# The functions the crates above call, each in the library that must define it. `[ _]` because
# Mach-O prefixes every C symbol with an underscore and ELF and x64 COFF do not.
check_defined() {
  # $1: symbols; $2: library name; $3…: entry points
  local symbols="$1" lib="$2" symbol
  shift 2
  for symbol in "$@"; do
    # A here-string rather than `printf … | grep -q`: under pipefail, grep -q exits on the first
    # match, the writer takes SIGPIPE, and a *found* symbol reads as a missing one.
    grep -qE "[ _]${symbol}$" <<<"$symbols" || {
      echo "$symbol is not defined in $lib" >&2
      exit 1
    }
  done
  echo "   $lib: $# entry points"
}
check_defined "$avcodec_defined" libavcodec \
  avcodec_find_decoder avcodec_alloc_context3 avcodec_open2 avcodec_send_packet \
  avcodec_receive_frame avcodec_flush_buffers avcodec_free_context avcodec_version \
  avcodec_configuration avcodec_license av_codec_iterate av_parser_iterate av_parser_init \
  av_parser_parse2 av_parser_close av_packet_alloc av_packet_free avcodec_default_get_format
check_defined "$avutil_defined" libavutil \
  av_frame_alloc av_frame_free av_frame_unref av_version_info avutil_version av_strerror \
  av_log_set_level av_get_cpu_flags av_force_cpu_flags av_get_pix_fmt_name \
  av_hwdevice_ctx_create av_hwframe_transfer_data av_buffer_ref av_buffer_unref

# The codec registry, read off the archive: FFCodec and FFCodecParser objects are *data*
# symbols named `ff_<name>_decoder` / `_encoder` / `_parser`, which is how `av_codec_iterate`
# finds them. Exactly `ff_hevc_decoder` and `ff_hevc_parser`, or the configuration above is not
# what was built. (Data only — `ff_init_cabac_decoder` is a function with a matching name.)
registry="$(awk '$1 !~ /^[TtUuWw]$/ { print $2 }' <<<"$avcodec_defined" | sed 's/^_//' |
  grep -E '^ff_[a-z0-9_]+_(decoder|encoder|parser)$' | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$registry" = "ff_hevc_decoder ff_hevc_parser" ] || {
  echo "the archive registers '$registry', not exactly ff_hevc_decoder ff_hevc_parser" >&2
  exit 1
}
echo "   registry: $registry"

# The kernels, as a gate. Counted on the HEVC DSP functions alone — libavutil's own kernels
# (float DSP, the FFT) would pad a count without saying anything about the decoder — and only
# as functions. The thresholds sit well under what 9.0.2 defines (x86_64: ~440 HEVC kernels, 90
# of them AVX2) and well over zero: they separate "the asm was built" from "it was not", which
# is the failure configure is capable of producing quietly.
echo ">> verifying the SIMD kernels are in the archive"
hevc_functions="$(awk '$1 ~ /^[Tt]$/ { print $2 }' <<<"$avcodec_defined" | sed 's/^_//' | grep -E '^ff_hevc_' || true)"
count() { grep -cE "$1" <<<"$hevc_functions" || true; }
case "$target" in
  linux-x86_64 | windows-x86_64-msvc)
    total="$(count '_(sse2|ssse3|sse4|avx|avx2)$')"
    avx2="$(count '_avx2$')"
    [ "$total" -ge 200 ] || { echo "only $total x86 HEVC kernels in libavcodec — the nasm objects were not built" >&2; exit 1; }
    [ "$avx2" -ge 40 ] || { echo "only $avx2 AVX2 HEVC kernels in libavcodec — the AVX2 kernels were not built" >&2; exit 1; }
    grep -qE '^ff_hevc_dsp_init_x86$' <<<"$hevc_functions" || { echo "ff_hevc_dsp_init_x86 is missing — nothing would dispatch the kernels" >&2; exit 1; }
    simd_evidence="$total HEVC kernels (sse2 $(count '_sse2$'), ssse3 $(count '_ssse3$'), sse4 $(count '_sse4$'), avx $(count '_avx$'), avx2 $avx2), ff_hevc_dsp_init_x86 dispatching"
    ;;
  *)
    neon="$(count '_neon$')"
    [ "$neon" -ge 50 ] || { echo "only $neon NEON HEVC kernels in libavcodec — the NEON objects were not built" >&2; exit 1; }
    grep -qE '^ff_hevc_dsp_init_aarch64$' <<<"$hevc_functions" || { echo "ff_hevc_dsp_init_aarch64 is missing — nothing would dispatch the kernels" >&2; exit 1; }
    simd_evidence="$((neon + $(count '_(dotprod|i8mm)$'))) HEVC kernels (neon $neon, dotprod $(count '_dotprod$'), i8mm $(count '_i8mm$')), ff_hevc_dsp_init_aarch64 dispatching"
    ;;
esac
echo "   $simd_evidence"

# Which system libraries the archives need — measured from their undefined symbols, because
# build.rs emits a link flag for each one the MANIFEST lists and nothing else.
echo ">> measuring the system libraries"
undefined="$( { list_symbols --undefined-only "${libs[0]}"; list_symbols --undefined-only "${libs[1]}"; } | awk '{print $2}' | sed 's/^_//' | sort -u)"
# The greps below are the one place where "found nothing" is an answer rather than a fault, so
# they accept exit 1 and nothing else: exit 2 is grep saying it could not do the search.
measure() {
  local status=0 matches
  matches="$(grep -E "$1" <<<"$undefined")" || status=$?
  [ "$status" -le 1 ] || { echo "grep failed ($status) while measuring" >&2; exit 1; }
  tr '\n' ' ' <<<"$matches" | sed 's/ *$//'
}
# FFmpeg's own statement, recorded verbatim per library beside the measurement for whoever
# compares them. It is a superset: configure adds `-latomic` whenever it merely links, and on
# macOS lists CoreServices, which the VideoToolbox hwaccel suggests and nothing compiled in
# references — measured below, and dropped.
extralibs="$(grep -E '^EXTRALIBS-(avcodec|avutil)=' "$config_mak" | sed 's/^EXTRALIBS-//' | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
system_libs=()
case "$target" in
  windows-*)
    # On MSVC the CRT and the C runtime's maths are one library the objects already name in
    # `/DEFAULTLIB` directives, and an undefined `__imp_BCryptGenRandom` says nothing about which
    # `.lib` holds it. FFmpeg's configure *does* know — it tested each by linking — so its
    # `foo.lib` list is taken as the answer here.
    for word in $extralibs; do
      word="${word#*=}"
      word="${word%;}"
      case "$word" in
        *.lib)
          case " ${system_libs[*]-} " in
            *" ${word%.lib} "*) ;;
            *) system_libs+=("${word%.lib}") ;;
          esac
          ;;
      esac
    done
    ;;
  linux-*)
    [ -z "$(measure '^(pow|powf|exp|exp2|expf|log|logf|log2|log10|sqrt|sqrtf|floor|ceil|round|lrint|lrintf|sin|cos|tan|sincos|atan|atan2|acos|asin|sinh|cosh|tanh|hypot|cbrt|fmod|frexp|scalbn|fmax|fmin|fabs)$')" ] || system_libs+=(m)
    [ -z "$(measure '^pthread_')" ] || system_libs+=(pthread)
    [ -z "$(measure '^__atomic_')" ] || system_libs+=(atomic)
    ;;
  macos-*)
    # libm and pthreads are libSystem, which every binary links; nothing to name.
    ;;
esac
if [ ${#system_libs[@]} -eq 0 ]; then system_libs_line=none; else system_libs_line="${system_libs[*]}"; fi
echo "   system_libs: $system_libs_line   (FFmpeg's EXTRALIBS: ${extralibs:-none})"

# The Apple frameworks, measured the same way: each framework FFmpeg's EXTRALIBS names is kept
# when the SDK's own export list for it — its `.tbd` — holds a symbol the archives leave
# undefined, and dropped otherwise, as CoreFoundation, CoreMedia and CoreVideo were before the
# hwaccel (see above). build.rs links each one the MANIFEST lists as a framework.
frameworks=()
case "$target" in
  macos-*)
    sdk="$(xcrun --show-sdk-path)"
    for name in $(grep -oE -- '-framework [A-Za-z]+' <<<"$extralibs" | awk '{print $2}' | sort -u); do
      tbd="$sdk/System/Library/Frameworks/$name.framework/$name.tbd"
      [ -f "$tbd" ] || { echo "the SDK has no $tbd for FFmpeg's -framework $name" >&2; exit 1; }
      exported="$(grep -oE "'?_[A-Za-z0-9_]+'?" "$tbd" | tr -d "'" | sed 's/^_//' | sort -u)"
      [ -z "$(comm -12 <(printf '%s\n' "$undefined") <(printf '%s\n' "$exported"))" ] || frameworks+=("$name")
    done
    ;;
esac
if [ ${#frameworks[@]} -eq 0 ]; then frameworks_line=none; else frameworks_line="${frameworks[*]}"; fi
echo "   frameworks: $frameworks_line"
# No C++ anywhere: FFmpeg is C. Asserted, because the day a C++ object appears the consumers
# need a runtime they are not linking.
cxx="$(measure '^(_Zn[wa]|_Zd[la]|_ZN?St|__cxa_|__gxx_personality|\?\?[23]@YA|.*@std@@)')"
[ -z "$cxx" ] || { echo "the archives reference the C++ runtime: $cxx" >&2; exit 1; }
echo "   no C++ runtime"
# Nor compiler-rt's availability checks, which no Rust link reliably carries (see the deployment
# target above): a newer check in a future FFmpeg fails here rather than in a consumer's LTO link.
availability="$(measure '^_*is(Platform|OS)VersionAtLeast$')"
[ -z "$availability" ] || { echo "the archives call compiler-rt's availability check: $availability" >&2; exit 1; }
echo "   no runtime availability checks"

crt='n/a'
if [ "$msvc" = 1 ]; then
  echo ">> verifying the CRT the objects name"
  directives="$(for lib in "${libs[@]}"; do llvm-readobj --coff-directives "$(np "$lib")"; done |
    grep -io 'DEFAULTLIB:"\{0,1\}[A-Za-z0-9_.]*' | sed 's/"//' | sort -u)"
  grep -qix 'DEFAULTLIB:MSVCRT' <<<"$directives" || {
    echo "no /DEFAULTLIB:MSVCRT directive — the objects do not name the dynamic CRT" >&2
    printf '  %s\n' "$directives" >&2
    exit 1
  }
  if grep -qi 'DEFAULTLIB:LIBCMT' <<<"$directives"; then
    echo "a static-CRT /DEFAULTLIB:LIBCMT directive is present — some object was built /MT" >&2
    exit 1
  fi
  crt='dynamic (MSVCRT)'
  echo "   $crt, and no LIBCMT"

  echo ">> verifying the objects name no PDB"
  for lib in "${libs[@]}"; do
    if grep -aqE '[A-Za-z0-9_:./\\-]+\.pdb' "$lib"; then
      echo "$(basename "$lib") names a PDB that is not shipped:" >&2
      grep -aoE '[A-Za-z0-9_:./\\-]+\.pdb' "$lib" | sort -u >&2
      exit 1
    fi
  done
  echo "   none"
fi

if [ -n "$deployment_target" ]; then
  echo ">> verifying the deployment target"
  for lib in "${libs[@]}"; do
    minos="$(otool -l "$lib" 2>/dev/null | awk '/minos/ {print $2}' | sort -u)"
    [ "$minos" = "$deployment_target" ] || {
      echo "$(basename "$lib") claims minos '$minos', not $deployment_target" >&2
      echo "  (more than one value means some objects missed the setting)" >&2
      exit 1
    }
  done
  echo "   minos $deployment_target on every member of both"
  floor="$floor, macOS $deployment_target"
fi

echo ">> checksumming the archives"
avcodec_sha="$(sha256_of "${libs[0]}")"
avutil_sha="$(sha256_of "${libs[1]}")"
echo "   $avcodec_sha  $(basename "${libs[0]}")"
echo "   $avutil_sha  $(basename "${libs[1]}")"

{
  echo "ffmpeg $FFMPEG_VERSION"
  echo "target $target"
  echo "source $FFMPEG_REPO"
  echo "commit $FFMPEG_COMMIT"
  echo "license $license"
  echo "sha256(avcodec) $avcodec_sha"
  echo "sha256(avutil) $avutil_sha"
  echo "libraries lib/$(basename "${libs[0]}") lib/$(basename "${libs[1]}")"
  echo "cpu_floor $floor"
  echo "system_libs $system_libs_line"
  echo "frameworks $frameworks_line"
  echo "extralibs(ffmpeg) ${extralibs:-none}"
  echo "crt $crt"
  echo "simd_config $simd_config"
  echo "simd_evidence $simd_evidence"
  echo "configure_args ${configure_args[*]}"
} >"$out/MANIFEST"

echo ">> wrote $out"
cat "$out/MANIFEST"
