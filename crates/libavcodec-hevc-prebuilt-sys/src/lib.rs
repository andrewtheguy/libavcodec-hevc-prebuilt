//! Raw FFI for FFmpeg's HEVC (H.265) decoder — libavcodec and libavutil, configured down to the
//! HEVC decoder and the HEVC parser — linked from prebuilt static archives.
//!
//! This crate builds no C. `build.rs` finds archives that were already built — by `./build.sh`
//! locally, or by this repository's release pipeline — verifies them against their own
//! MANIFEST, and emits the link flags. A consumer needs no FFmpeg, no nasm, no C compiler and no
//! LLVM.
//!
//! Everything public comes from [`bindings`], bindgen's output over the headers committed in
//! `include/`, re-exported at the crate root so `avcodec_hevc_sys::avcodec_send_packet` reads
//! the way the C does. A handful of FFmpeg's macros are function-like and bindgen cannot evaluate
//! them; the ones a decoder loop needs are defined here by hand: [`AVERROR_EOF`],
//! [`AVERROR_EAGAIN`], [`AVERROR_INVALIDDATA`], [`averror`] and [`AV_NOPTS_VALUE`].
//!
//! # What is in the archives, and what is not
//!
//! `avcodec_find_decoder(AV_CODEC_ID_HEVC)` and `av_parser_init(AV_CODEC_ID_HEVC)` — Main, Main
//! 10, Main 12 and the range extensions FFmpeg implements, with frame and slice (WPP) threading.
//! **Nothing else**: no other codec, no encoder, no bitstream filter, no hwaccel, no demuxer.
//! `av_codec_iterate` yields exactly one codec. On x86_64 the SSE2…AVX2 kernels, and on arm64 the
//! NEON (plus i8mm) kernels, are chosen at run time from `av_get_cpu_flags()`.
//!
//! # Safety
//!
//! Nothing here is safe. An `AVCodecContext` must be freed exactly once with
//! `avcodec_free_context`; a frame from `avcodec_receive_frame` is the caller's until
//! `av_frame_unref`; `av_parser_parse2`'s output points into the parser's buffer and is
//! invalidated by the next call; and plane `linesize`s are in *bytes*, which for bit depths above
//! 8 covers two bytes per sample.
//!
//! # Licence
//!
//! This FFmpeg configuration is LGPL-2.1-or-later, and this crate links it **statically** into
//! your binary. The LGPL permits that, with obligations — chiefly, that a recipient of your binary
//! be able to relink it against a modified FFmpeg. Read the repository's README before shipping a
//! closed-source binary that depends on this crate.

// bindgen's own header already carries the allow attributes these names need.
//
// Two generated files, not one: a C enum is always `int` to MSVC, where clang on the other
// targets makes an enum with no negative values `unsigned`. One file covers macOS and both Linux
// architectures, because every C integer type in it is an alias each target resolves for itself.
//
// Clippy is off for the generated file: it is bindgen's output and is regenerated, never edited,
// and libavutil's mathematics.h constants (`M_PI`, `M_LN2`, …) trip `approx_constant` on sight.
#[cfg_attr(windows, path = "bindings_windows.rs")]
#[allow(clippy::all)]
mod bindings;

pub use bindings::*;

use std::os::raw::c_int;

/// `FFERRTAG(a, b, c, d)`: the negated little-endian four-character code FFmpeg's own error
/// codes are built from.
pub const fn fferrtag(tag: [u8; 4]) -> c_int {
    // `MKTAG` in unsigned arithmetic, then `-(int)`, exactly as libavutil/error.h spells it.
    let tag = (tag[0] as u32)
        | ((tag[1] as u32) << 8)
        | ((tag[2] as u32) << 16)
        | ((tag[3] as u32) << 24);
    -(tag as c_int)
}

/// `AVERROR_EOF`: the decoder has been drained and will output nothing more.
pub const AVERROR_EOF: c_int = fferrtag(*b"EOF ");
/// `AVERROR_INVALIDDATA`: the input is not valid — including, with `AV_EF_CRCCHECK |
/// AV_EF_EXPLODE` set, a picture that fails the stream's own MD5 picture-hash SEI.
pub const AVERROR_INVALIDDATA: c_int = fferrtag(*b"INDA");

/// `AVERROR(e)`: FFmpeg reports POSIX errors negated.
pub const fn averror(errno: c_int) -> c_int {
    -errno
}

/// `EAGAIN` as the platform's C library defines it — FFmpeg's `AVERROR(EAGAIN)` is its negation,
/// so the value differs between targets. 11 on Linux and in the MSVC CRT, 35 on Apple platforms.
#[cfg(any(target_vendor = "apple", target_os = "freebsd"))]
pub const EAGAIN: c_int = 35;
/// `EAGAIN` as the platform's C library defines it — FFmpeg's `AVERROR(EAGAIN)` is its negation,
/// so the value differs between targets. 11 on Linux and in the MSVC CRT, 35 on Apple platforms.
#[cfg(not(any(target_vendor = "apple", target_os = "freebsd")))]
pub const EAGAIN: c_int = 11;

/// `AVERROR(EAGAIN)`: `avcodec_receive_frame` has nothing to return until more input is sent, or
/// `avcodec_send_packet` will take nothing more until output is received.
pub const AVERROR_EAGAIN: c_int = averror(EAGAIN);

/// `AV_NOPTS_VALUE`: an undefined timestamp.
pub const AV_NOPTS_VALUE: i64 = i64::MIN;

/// What the linked FFmpeg says it is, e.g. `9.0.2` — `av_version_info()`, which build.sh sets to
/// the release number rather than letting FFmpeg's build ask git. The version this crate's
/// bindings were generated against is [`PREBUILT_VERSION`].
pub fn version() -> &'static str {
    // SAFETY: `av_version_info` takes no arguments, cannot fail, and returns a pointer to a
    // string literal compiled into libavutil — genuinely 'static, nothing to free.
    let ptr = unsafe { av_version_info() };
    assert!(!ptr.is_null(), "av_version_info returned null");
    // SAFETY: as above — a NUL-terminated string constant in the archive's read-only data.
    unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().expect("FFmpeg's version string is ASCII")
}

/// The FFmpeg version this crate's bindings and archives are built from, from `ffmpeg.env`.
pub const PREBUILT_VERSION: &str = env!("FFMPEG_PREBUILT_VERSION");
