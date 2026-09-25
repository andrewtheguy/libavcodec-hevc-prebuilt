# AGENTS.md

## Before `cargo` anything

Every crate here links the archives, so cargo cannot build until they exist:

```sh
./build.sh <target>     # the target this machine is (see build.sh's usage for the list)
./sync-prebuilt.sh      # dist/ -> crates/libavcodec-hevc-prebuilt-sys/prebuilt/
```

`./sync-prebuilt.sh --fetch` is the alternative once a release exists. Neither `clippy` nor
`test` works without one of the two, which is why CI runs clippy inside the build job rather
than beside it. x86_64 builds need `nasm`.

## This machine builds one target

`./build.sh` does not cross-compile. Linux x86_64 is gated here with `ci/unix/remote.sh`; the
others through `../devtools`: `ci/unix/remote.sh -a ci` (linux/arm64 build box, remote-lxc),
`ci/unix/remote.sh -H macvm ci` (macOS), `ci/windows/remote.ps1 ci` (Windows box), or
`workflow_dispatch` on **Build libavcodec-hevc**. Do not add a cross-compilation path without
measuring what it produces; the point of the MANIFEST is that every claim in it was checked on the
artifact. Don't run `./build.sh` locally while a remote driver is packing the tree — it deletes
`build/<target>` under the packer.

`src/bindings_windows.rs` is generated on Windows only (`ci/windows/ci.ps1` regenerates it; bring
it back with `ci/windows/remote.ps1 fetch crates\libavcodec-hevc-prebuilt-sys\src <dest>`).

## Bootstrapping order

The download paths cannot pass before a release exists. On a fresh fork: run **Build
libavcodec-hevc** (`workflow_dispatch`, `targets: all`) by hand, then **Release libavcodec-hevc
archives**.

## What not to "fix"

- **`--disable-everything --disable-autodetect`, then only `--enable-decoder=hevc
  --enable-parser=hevc`.** Anything autodetected is a system library at every consumer's link.
  `--disable-iconv` is spelled out because glibc makes the iconv probe succeed anyway.
- **No encoder.** FFmpeg has none of its own for HEVC; libx265 is GPL + C++ and would change the
  licence and the link of every consumer. The e2e test does not need one.
- **`REVISION=$FFMPEG_VERSION` on make's command line** is what makes `av_version_info()` say
  `9.0.2` instead of a git hash; the e2e binary asserts it.
- **No `--prefix`, no paths in the configure line**: FFmpeg compiles the line into the library
  (`avcodec_configuration()`), so a path would be the build machine's, in every binary.
- **No CPU floor on x86_64**: the kernels are dispatched at run time.
- **`-MD` on Windows**: FFmpeg's MSVC toolchain names no CRT, which cl takes as `/MT`.
- **No musl mapping** in build.rs: the Linux archives reference glibc-only symbols.
- **The e2e fixtures are shared with libde265-prebuilt, byte for byte, and committed.** The
  reference is a separate FFmpeg's decode, CI checks it with the runner's ffmpeg, and a
  regeneration has to go to both repositories.
- **The va_list functions are blocklisted in gen-bindings.sh**: `va_list` differs per target, and
  one `bindings.rs` covers three.
