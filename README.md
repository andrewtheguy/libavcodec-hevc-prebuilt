# libavcodec-hevc-prebuilt

Static **FFmpeg 9.0.2 libavcodec + libavutil, configured down to the HEVC / H.265 decoder and the
HEVC parser**, built once so that nothing which *links* it needs FFmpeg, nasm, a C toolchain or a
system package at all.

```toml
avcodec-hevc-sys = { package = "libavcodec-hevc-prebuilt-sys", git = "https://github.com/andrewtheguy/libavcodec-hevc-prebuilt", tag = "v9.0.2-…" }
```

The crate's `[lib] name` is `avcodec_hevc_sys`, so the calls read
`avcodec_hevc_sys::avcodec_send_packet(…)`.

No configure, no nasm, no C compiler, no pkg-config, no libclang, and nothing to set in the
environment. `build.rs` downloads the archives for its target from this repository's latest
release, checks them, and emits the link flags. There is one variable,
`LIBAVCODEC_HEVC_PREBUILT_DIR`, and it is an opt-in override for archives you built yourself
([below](#local-loop)).

This is the FFmpeg twin of [libde265-prebuilt](https://github.com/andrewtheguy/libde265-prebuilt)
and [libvpx-prebuilt](https://github.com/andrewtheguy/libvpx-prebuilt), and follows them closely:
same layout, same chain of checks, same release model. It exists because libde265 needed a fork
to decode multi-slice streams with SAO correctly; FFmpeg's HEVC decoder is the most widely used
and most fuzzed one there is, and this repository builds an **unpatched** release of it.

This repository is not a fork of FFmpeg and carries none of its source: `source.sh` fetches the
pinned commit into `build/` (gitignored) at build time.

## Layout

```
ffmpeg.env                           the pin: version, commit, source repo, release repo
source.sh                            fetch the pinned commit, assert it; the feature switches
build.sh <target>                    configure, make, verify, write dist/<target>/MANIFEST
sync-prebuilt.sh                     dist/ -> the crate's cache; --headers; --check; --fetch
check-static.sh <binary>             assert a finished binary carries libavcodec and links none
crates/libavcodec-hevc-prebuilt-sys/ the FFI crate: committed headers, committed bindings, build.rs
crates/libavcodec-hevc-e2e/          a consumer that decodes committed HEVC streams bit-exactly
ci/unix/, ci/windows/                the build.yml rows, runnable here and on the remote builders
```

Targets: `macos-arm64`, `linux-x86_64`, `linux-aarch64`, `windows-x86_64-msvc`. The Windows
archives are `avcodec.lib` and `avutil.lib`, MSVC against the dynamic CRT (`/MD`), for
`x86_64-pc-windows-msvc` only. **No musl** — see [below](#what-a-consumer-links).

## What is in the archives

FFmpeg configured with `--disable-everything --disable-autodetect`, and then two components
back: **`--enable-decoder=hevc --enable-parser=hevc`**. That is Main, Main 10, Main 12 and the
range extensions FFmpeg implements, with frame and slice (WPP) threading; and the parser, which
turns an Annex B byte stream in arbitrary chunks into the packets `avcodec_send_packet` wants.
Only libavcodec and libavutil are built. No other codec, no bitstream filter, no hwaccel, no
demuxer, no zlib/iconv/VAAPI/VideoToolbox/CUDA — nothing autodetected, so nothing on the build
machine can leak into the archive as a link-time dependency.

**No encoder.** FFmpeg has no HEVC encoder of its own: `hevc` encoding in FFmpeg means libx265
(GPL, C++, its own cmake build), or a hardware encoder (NVENC, QSV, VideoToolbox, VAAPI, AMF,
MediaCodec) that needs a vendor SDK and a GPU. Either would turn this LGPL, C-only, dependency-free
archive into something else, and the end-to-end test does not need one — see
[below](#the-end-to-end-test).

`build.sh` then asserts what it configured, rather than trusting it:

- the licence configure reports is **LGPL version 2.1 or later** — nothing GPL or non-free got in;
- `config_components.h` enables exactly the HEVC decoder and parser, and no encoder, bsf or
  hwaccel; and the archive's codec registry, read with `nm`, holds exactly `ff_hevc_decoder` and
  `ff_hevc_parser`;
- the 27 entry points the crates call are defined, each in the library it must be in;
- `CONFIG_RUNTIME_CPUDETECT` is on, and the SIMD configuration it needs is too;
- the SIMD kernels are in the archive, counted ([below](#simd-and-no-cpu-floor));
- the system libraries the archives need are **measured** from their undefined symbols, and
  `build.rs` emits link flags from the measurement; and no symbol reaches for a C++ runtime;
- on Windows, every member is a real COFF object (no `/GL` blobs), the objects name the dynamic
  CRT and not the static one, and none names an unshipped PDB;
- on macOS the deployment target is read back off every member (`minos 11.0`).

`av_version_info()` returns `9.0.2`: build.sh passes the release number as `REVISION`, where
FFmpeg's build would otherwise ask `git describe` in a one-commit-deep checkout and get a hash.

## SIMD, and no CPU floor

**x86_64: no floor, deliberately** — the same argument as libvpx-prebuilt and libde265-prebuilt.
FFmpeg's x86 kernels are nasm assembly, one function per instruction set, and
`ff_hevc_dsp_init_x86` installs whichever the CPU supports from `av_get_cpu_flags()` at run time.
A `-march` floor could not decide which runs; it could only cost the archive every machine below
it. The linux-x86_64 archive holds **440 HEVC kernels** (SSE2 66, SSSE3 12, SSE4.1 234, AVX 38,
AVX2 90); build.sh fails below 200, or below 40 AVX2.

**arm64: NEON is the ARMv8-A baseline**, and FFmpeg's HEVC NEON kernels are aarch64 assembly the
C compiler assembles — no nasm. linux-aarch64 holds **430** (NEON 322, i8mm 108); the i8mm ones
are chosen at run time. build.sh fails below 50 NEON kernels.

The e2e binary then checks the other half: that FFmpeg *detects* the architecture's baseline at
run time (SSE2, NEON), and that every stream decodes bit-exactly with the kernels and with
`av_force_cpu_flags(0)`. It prints the speed-up too, as evidence the kernels are dispatched.
Measured (8-bit / 10-bit): 1.7× / 1.45× on Linux x86_64, 1.9× / 1.5× on Windows, 1.6× / 1.1× on
the arm64 Linux build box (no i8mm), 1.5× / 1.1× on Apple silicon. FFmpeg's 10-bit NEON coverage
is thinner than its x86 coverage, which is what the arm64 10-bit number shows.

## What a consumer links

FFmpeg is C, so unlike libde265-prebuilt there is **no C++ runtime** to carry. What the archives
need is measured into the MANIFEST as `system_libs` and emitted by `build.rs`: `m pthread` on
Linux, nothing on macOS (libSystem), and on Windows what FFmpeg's own configure tested and
recorded — `ole32 user32 bcrypt`, all of them part of every Windows install.

**No musl mapping.** The Linux archives are compiled against glibc and reference glibc-only
names — `__isoc99_sscanf`, `__xpg_strerror_r`, the LFS64 aliases (`open64`, `fstat64`) that musl
1.2.4 stopped exporting. Set `LIBAVCODEC_HEVC_PREBUILT_DIR` to your own musl build instead.

## The chain

```
ffmpeg.env pins a commit
  -> source.sh fetches that commit, asserts HEAD and its RELEASE file, refuses a dirty tree
    -> build.sh compiles that tree and writes sha256 of both libraries into a MANIFEST
      -> the release publishes the archives plus SHA256SUMS
        -> build.rs verifies the download against SHA256SUMS
          -> and the extracted libraries against the MANIFEST beside them, on every path
```

and, separately, the part a reviewer can read:

```
include/          is what FFmpeg's own `make install-headers` installs from the pinned commit,
                  with the same feature switches                 (sync-prebuilt.sh --check)
                  and what `make install` produced in each real build (the same, with dist/ present)
src/bindings.rs   is what bindgen 0.72.1 makes of those headers  (gen-bindings.sh --check)
```

SHA256SUMS is a corruption check, not a tamper check: it lives on the same release as the files
it covers. The pin that constrains someone other than this repository is `FFMPEG_COMMIT`,
asserted against the fetched tree before a compiler runs.

On `linux-x86_64` the pipeline also builds the libraries **twice**, the second time from a clean
tree, and requires the checksums to match. Only there: GNU ar zeroes member mtimes and uids
(FFmpeg's configure asks for `rcD`), but Apple's ar and lib.exe stamp their members.

## The bindings

bindgen's output over the committed headers, one file for macOS and both Linux architectures and
one for Windows (MSVC types every C enum `int`). Two deliberate gaps:

- the five functions taking a `va_list` (`av_vlog`, `av_log_set_callback`,
  `av_log_default_callback`, `av_log_format_line{,2}`) are left out, because `va_list` is a
  different type on each target one file covers. `av_log_set_level` and `av_log` are there;
- function-like macros cannot be bound, so `lib.rs` defines the ones a decode loop needs:
  `AVERROR_EOF`, `AVERROR_EAGAIN` (whose value differs per platform), `AVERROR_INVALIDDATA`,
  `averror()` and `AV_NOPTS_VALUE`. The e2e binary checks the error constants against what
  libavcodec actually returns on each target.

## The end-to-end test

No encoder means `libavcodec-hevc-e2e` cannot make its own input, and it does not need to. Its
two streams in `crates/libavcodec-hevc-e2e/testdata/` are **the same bytes libde265-prebuilt
tests with**, encoded by libx265 from ffmpeg's synthetic `testsrc2`; beside each is one SHA-256
per frame of a separate FFmpeg's decode (the distribution's, not this build). HEVC decoding is
exactly specified: libde265 reproduces those hashes in its repository, and this binary requires
the pinned libavcodec to reproduce them here. `gen-testdata.sh` records how both were made, and
CI re-derives the hashes with whichever ffmpeg the runner has.

On every target, the binary checks the version and licence, that the registry holds exactly the
HEVC decoder and parser, and the CPU flags; then decodes both streams — 8-bit with B-frames, and
10-bit with three slices per picture and SAO (the stream that exposed libde265's bug) — through
the parser, with SIMD on, with SIMD off, with four frame threads and with four slice threads, and
requires every frame to match, with the stream's in-band MD5 picture hashes verified
(`AV_EF_CRCCHECK | AV_EF_EXPLODE`). It proves that check is live (skipping the loop filters must
fail it), and that a stream cut at 60% ends cleanly with every frame before the cut still right.

## Local loop

```sh
./build.sh <target>             # -> dist/<target>/{lib,include,MANIFEST}
./sync-prebuilt.sh              # -> crates/libavcodec-hevc-prebuilt-sys/prebuilt/, what cargo links
cargo run --release -p libavcodec-hevc-e2e
./check-static.sh target/release/libavcodec-hevc-e2e
```

Building needs a C compiler, make, and on x86_64 **nasm**. `<target>` is the one this machine
*is* — `./build.sh` does not cross-compile. The whole gate, as build.yml runs it, is
`ci/unix/ci.sh`; through `../devtools`, `ci/unix/remote.sh` runs it here, `ci/unix/remote.sh -a
ci` on the linux/arm64 build box and `ci/unix/remote.sh -H macvm ci` on the Mac, and
`ci/windows/remote.ps1 ci` on the Windows box. Or a `workflow_dispatch` on **Build
libavcodec-hevc**.

`./sync-prebuilt.sh --fetch` pulls the latest release's archives instead.
`LIBAVCODEC_HEVC_PREBUILT_DIR` points `build.rs` at a prefix you built yourself — the escape hatch
for an unsupported target, musl, or more of FFmpeg — and `build.rs` warns that nothing about it
was checked.

## Bootstrapping

The download paths cannot pass before the first release exists, so on a fresh fork: run **Build
libavcodec-hevc** by hand (`workflow_dispatch`, `targets: all`), then **Release libavcodec-hevc
archives**.

## Which library got linked

```sh
cargo build -vv 2>&1 | grep -E 'libavcodec|FFmpeg'
```

`build.rs` emits the provenance, the version, the checksum results, the CPU floor and the SIMD
evidence as `cargo:info` lines. At run time `avcodec_hevc_sys::version()` is what the archive
reports and `avcodec_hevc_sys::PREBUILT_VERSION` is what this repository pinned; the e2e binary
asserts they agree.

## Licensing

This FFmpeg configuration is **LGPL-2.1-or-later** (`LICENSE.md` and `COPYING.LGPLv2.1`, at the
root and in every archive), and these are **static** archives. That combination is allowed, and
it has conditions a BSD library does not: whoever distributes a program that links them must let
recipients relink it against a modified FFmpeg — in practice, ship your object files or your
source alongside the binary — and must pass on the licence and FFmpeg's source (the pinned
commit, unmodified). If that does not suit a closed-source product, the options are dynamic
linking against an FFmpeg shared library (not what this repository builds) or a different
decoder.

HEVC is also covered by patent pools. Nothing in FFmpeg's licence, or in this repository, grants
patent rights; whether a product needs a patent licence is a question for whoever ships it.
